#!/bin/bash
# Connects to the HIVE DB bastion over AWS SSM Session Manager (no SSH, no
# public IP, no open port). Subcommands:
#   status  bastion instance, SSM registration and RDS endpoint (read-only)
#   shell   interactive shell on the bastion
#   tunnel  forward RDS to localhost:<port> and keep it open until Ctrl-C
#   psql    open the tunnel, read the password into the environment, start psql,
#           close the tunnel when psql exits

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${SCRIPT_DIR}/logs"

readonly DEFAULT_REGION="eu-central-1"
readonly DEFAULT_DB_INSTANCE="hive-pg"
readonly DEFAULT_BASTION_NAME="hive-bastion"
readonly DEFAULT_LOCAL_PORT="5433"
readonly PORT_WAIT_SECONDS=60

# Set in main once --log-file is known. Empty means terminal only.
LOG_FILE=""
# Background SSM session opened by the psql subcommand, stopped on exit.
SESSION_PID=""

function log {
  local readonly level="$1"
  local readonly message="$2"
  local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local readonly line="${timestamp} [${level}] [$SCRIPT_NAME] ${message}"

  >&2 echo -e "$line"

  if [[ -n "$LOG_FILE" ]]; then
    echo -e "$line" >> "$LOG_FILE"
  fi
}

function log_info {
  local readonly message="$1"
  log "INFO" "$message"
}

function log_warn {
  local readonly message="$1"
  log "WARN" "$message"
}

function log_error {
  local readonly message="$1"
  log "ERROR" "$message"
}

function print_usage {
  echo
  echo "Usage: $SCRIPT_NAME <status|shell|tunnel|psql> [OPTIONS]"
  echo
  echo "Reach the HIVE RDS database through the SSM bastion. There is no SSH: access is your"
  echo "IAM identity (export AWS_PROFILE=<profile>) and every session is logged in CloudTrail."
  echo
  echo "Subcommands:"
  echo
  echo -e "  status\t\tShow the bastion, its SSM registration and the RDS endpoint. Read-only."
  echo -e "  shell\t\t\tInteractive shell on the bastion (psql 16 client is installed there)."
  echo -e "  tunnel\t\tForward RDS to localhost:<local-port>; stays open until Ctrl-C."
  echo -e "  psql\t\t\tTunnel + password from Secrets Manager + interactive psql; closes on exit."
  echo
  echo "Options:"
  echo
  echo -e "  --region\t\tAWS region. Optional. Default: $DEFAULT_REGION"
  echo -e "  --db-instance\t\tRDS instance identifier. Optional. Default: $DEFAULT_DB_INSTANCE"
  echo -e "  --bastion-name\tName tag of the bastion. Optional. Default: $DEFAULT_BASTION_NAME"
  echo -e "  --local-port\t\tLocal port for tunnel/psql. Optional. Default: $DEFAULT_LOCAL_PORT"
  echo -e "  --log-file\t\tAppend all output to this file as well as the terminal."
  echo -e "  \t\t\tDefault: scripts/logs/<UTC timestamp>.log"
  echo -e "  --no-log-file\t\tTerminal only, write no log file."
  echo
  echo "Examples:"
  echo
  echo "  AWS_PROFILE=<profile> $SCRIPT_NAME status"
  echo "  AWS_PROFILE=<profile> $SCRIPT_NAME psql"
  echo "  AWS_PROFILE=<profile> $SCRIPT_NAME tunnel --local-port 5433"
  echo
  echo "Dump: scripts/db-dump.sh"
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    if [[ "$name" == "session-manager-plugin" ]]; then
      log_error "Install it with: brew install --cask session-manager-plugin"
    fi
    exit 1
  fi
}

function cleanup {
  if [[ -n "$SESSION_PID" ]] && kill -0 "$SESSION_PID" 2>/dev/null; then
    log_info "closing SSM tunnel (pid $SESSION_PID)"
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  unset PGPASSWORD
}

function port_is_open {
  local readonly port="$1"
  nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

# Prints the running bastion's instance id, or nothing.
function find_bastion {
  local readonly region="$1"
  local readonly name="$2"
  local id=""

  id=$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Name,Values=${name}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text) || return 1
  if [[ "$id" != "None" ]]; then
    echo "$id"
  fi
}

function require_bastion {
  local readonly region="$1"
  local readonly name="$2"
  local id=""

  id=$(find_bastion "$region" "$name")
  if [[ -z "$id" ]]; then
    log_error "no running instance tagged Name=$name in $region (is enable_bastion applied?)"
    exit 1
  fi
  echo "$id"
}

# Prints "<endpoint-address> <master-secret-arn>".
function describe_db {
  local readonly region="$1"
  local readonly db_instance="$2"

  aws rds describe-db-instances --region "$region" --db-instance-identifier "$db_instance" \
    --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text || return 1
}

# Prints the password only; callers put it straight into PGPASSWORD.
function read_db_password {
  local readonly region="$1"
  local readonly secret_arn="$2"
  local secret_json=""

  secret_json=$(aws secretsmanager get-secret-value --region "$region" --secret-id "$secret_arn" \
    --query SecretString --output text) || return 1
  python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' <<< "$secret_json" || return 1
}

function cmd_status {
  local readonly region="$1"
  local readonly bastion_name="$2"
  local readonly db_instance="$3"
  local id=""
  local ping=""
  local db_info=""

  id=$(find_bastion "$region" "$bastion_name")
  if [[ -z "$id" ]]; then
    log_warn "bastion  : not running (no instance tagged Name=$bastion_name; is enable_bastion applied?)"
  else
    ping=$(aws ssm describe-instance-information --region "$region" \
      --filters "Key=InstanceIds,Values=${id}" \
      --query 'InstanceInformationList[0].PingStatus' --output text)
    log_info "bastion  : $id (SSM: ${ping:-not registered yet})"
  fi

  db_info=$(describe_db "$region" "$db_instance")
  log_info "database : $db_instance ($(echo "$db_info" | awk '{print $1}'))"

  if command -v session-manager-plugin >/dev/null 2>&1; then
    log_info "plugin   : session-manager-plugin $(session-manager-plugin --version 2>/dev/null)"
  else
    log_warn "plugin   : session-manager-plugin missing (brew install --cask session-manager-plugin)"
  fi
}

function cmd_shell {
  local readonly region="$1"
  local readonly bastion_id="$2"

  log_info "opening shell on $bastion_id (exit to leave)"
  aws ssm start-session --region "$region" --target "$bastion_id"
}

function start_tunnel_background {
  local readonly region="$1"
  local readonly bastion_id="$2"
  local readonly db_host="$3"
  local readonly local_port="$4"
  local readonly session_log="$5"

  aws ssm start-session --region "$region" --target "$bastion_id" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${db_host},portNumber=5432,localPortNumber=${local_port}" \
    > "$session_log" 2>&1 &
  SESSION_PID=$!

  local waited=0
  until port_is_open "$local_port"; do
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      log_error "SSM session exited early; its output is in $session_log"
      exit 1
    fi
    if [[ "$waited" -ge "$PORT_WAIT_SECONDS" ]]; then
      log_error "port $local_port did not open within ${PORT_WAIT_SECONDS}s; see $session_log"
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log_info "tunnel up: localhost:$local_port -> $db_host:5432 (after ${waited}s)"
}

function cmd_tunnel {
  local readonly region="$1"
  local readonly bastion_id="$2"
  local readonly db_host="$3"
  local readonly local_port="$4"

  log_info "tunnel: localhost:$local_port -> $db_host:5432 via $bastion_id (Ctrl-C to close)"
  log_info "connect: PGHOST=localhost PGPORT=$local_port PGUSER=hive PGDATABASE=hive PGSSLMODE=require psql"
  log_info "password: $SCRIPT_NAME psql does this for you, or read it from Secrets Manager into PGPASSWORD"
  aws ssm start-session --region "$region" --target "$bastion_id" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${db_host},portNumber=5432,localPortNumber=${local_port}"
}

function cmd_psql {
  local readonly region="$1"
  local readonly bastion_id="$2"
  local readonly db_host="$3"
  local readonly secret_arn="$4"
  local readonly local_port="$5"

  mkdir -p "$LOG_DIR"
  start_tunnel_background "$region" "$bastion_id" "$db_host" "$local_port" \
    "${LOG_DIR}/ssm-$(date -u +"%Y%m%dT%H%M%SZ").log"

  export PGHOST=127.0.0.1 PGPORT="$local_port" PGUSER=hive PGDATABASE=hive PGSSLMODE=require
  PGPASSWORD=$(read_db_password "$region" "$secret_arn")
  export PGPASSWORD
  assert_not_empty "database password" "$PGPASSWORD"

  log_info "starting psql as hive@$db_host (\\q to quit; tunnel closes afterwards)"
  # Not exec: cleanup must run after psql to close the tunnel and drop the password.
  psql || log_warn "psql exited with status $?"
}

function main {
  local subcommand=""
  local region="$DEFAULT_REGION"
  local db_instance="$DEFAULT_DB_INSTANCE"
  local bastion_name="$DEFAULT_BASTION_NAME"
  local local_port="$DEFAULT_LOCAL_PORT"
  local log_file_arg=""
  local no_log_file="false"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      status|shell|tunnel|psql)
        subcommand="$key"
        ;;
      --region)
        region="$2"
        shift
        ;;
      --db-instance)
        db_instance="$2"
        shift
        ;;
      --bastion-name)
        bastion_name="$2"
        shift
        ;;
      --local-port)
        local_port="$2"
        shift
        ;;
      --log-file)
        log_file_arg="$2"
        shift
        ;;
      --no-log-file)
        no_log_file="true"
        ;;
      --help|-h|help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  assert_not_empty "subcommand (status|shell|tunnel|psql)" "$subcommand"
  assert_not_empty "--region" "$region"
  assert_not_empty "--db-instance" "$db_instance"
  assert_not_empty "--bastion-name" "$bastion_name"
  assert_not_empty "--local-port" "$local_port"

  if [[ "$no_log_file" != "true" ]]; then
    local candidate=""
    if [[ -n "$log_file_arg" ]]; then
      candidate="$log_file_arg"
    else
      mkdir -p "$LOG_DIR"
      candidate="${LOG_DIR}/$(date -u +"%Y%m%dT%H%M%SZ").log"
    fi

    if ! touch "$candidate" 2>/dev/null; then
      log_error "cannot write to log file '$candidate'"
      exit 1
    fi

    LOG_FILE="$candidate"
    log_info "log file : $LOG_FILE"
  fi

  assert_is_installed "aws"
  assert_is_installed "python3"

  if [[ "$subcommand" == "status" ]]; then
    cmd_status "$region" "$bastion_name" "$db_instance"
    return
  fi

  assert_is_installed "session-manager-plugin"
  trap cleanup EXIT

  local bastion_id=""
  bastion_id=$(require_bastion "$region" "$bastion_name")

  if [[ "$subcommand" == "shell" ]]; then
    cmd_shell "$region" "$bastion_id"
    return
  fi

  local db_info=""
  db_info=$(describe_db "$region" "$db_instance")
  local readonly db_host=$(echo "$db_info" | awk '{print $1}')
  local readonly secret_arn=$(echo "$db_info" | awk '{print $2}')
  assert_not_empty "db endpoint" "$db_host"

  if port_is_open "$local_port"; then
    log_error "local port $local_port is already in use; pick another with --local-port"
    exit 1
  fi

  case "$subcommand" in
    tunnel)
      assert_is_installed "nc"
      cmd_tunnel "$region" "$bastion_id" "$db_host" "$local_port"
      ;;
    psql)
      assert_is_installed "nc"
      assert_is_installed "psql"
      assert_not_empty "db master secret" "$secret_arn"
      cmd_psql "$region" "$bastion_id" "$db_host" "$secret_arn" "$local_port"
      ;;
  esac
}

main "$@"
