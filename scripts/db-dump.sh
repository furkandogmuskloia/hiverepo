#!/bin/bash
# Takes a consistent, read-only dump of the HIVE RDS database through the SSM
# bastion: opens a port-forward, reads the password from Secrets Manager into
# the environment (never printed), records row counts, runs pg_dump -Fc, writes
# a sha256, verifies the archive and closes the session. Optionally restores
# the dump into a throwaway container and compares counts.

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${SCRIPT_DIR}/logs"

readonly DEFAULT_REGION="eu-central-1"
readonly DEFAULT_DB_INSTANCE="hive-pg"
readonly DEFAULT_BASTION_NAME="hive-bastion"
readonly DEFAULT_LOCAL_PORT="5433"
readonly DEFAULT_OUT_DIR="${SCRIPT_DIR}/../dumps"
readonly PORT_WAIT_SECONDS=60
readonly EXPECTED_TABLES=3

# Set in main once --log-file is known. Empty means terminal only.
LOG_FILE=""
# Background SSM session, stopped by cleanup on any exit.
SESSION_PID=""
RESTORE_CONTAINER=""

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
  echo "Usage: $SCRIPT_NAME [OPTIONS]"
  echo
  echo "Read-only dump of the HIVE RDS database via the SSM bastion (no SSH, no public IP)."
  echo "AWS credentials come from the standard chain: export AWS_PROFILE=<profile> first."
  echo
  echo "Options:"
  echo
  echo -e "  --region\t\tAWS region. Optional. Default: $DEFAULT_REGION"
  echo -e "  --db-instance\t\tRDS instance identifier. Optional. Default: $DEFAULT_DB_INSTANCE"
  echo -e "  --bastion-name\tName tag of the SSM bastion. Optional. Default: $DEFAULT_BASTION_NAME"
  echo -e "  --local-port\t\tLocal port for the port-forward. Optional. Default: $DEFAULT_LOCAL_PORT"
  echo -e "  --out-dir\t\tWhere dump, counts and sha256 are written. Optional."
  echo -e "  \t\t\tDefault: dumps/ at the repo root (gitignored)."
  echo -e "  --restore-check\tAlso restore into a throwaway postgres:16 container (needs docker)"
  echo -e "  \t\t\tand compare row counts. Optional."
  echo -e "  --log-file\t\tAppend all output to this file as well as the terminal."
  echo -e "  \t\t\tDefault: scripts/logs/<UTC timestamp>.log"
  echo -e "  --no-log-file\t\tTerminal only, write no log file."
  echo
  echo "Example:"
  echo
  echo "  AWS_PROFILE=<profile> $SCRIPT_NAME --restore-check"
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
    exit 1
  fi
}

function cleanup {
  if [[ -n "$SESSION_PID" ]] && kill -0 "$SESSION_PID" 2>/dev/null; then
    log_info "closing SSM session (pid $SESSION_PID)"
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  if [[ -n "$RESTORE_CONTAINER" ]]; then
    docker rm -f "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
  fi
  unset PGPASSWORD
}

function port_is_open {
  local readonly port="$1"
  nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

# Prints the running bastion's instance id. Empty output means none found.
function find_bastion {
  local readonly region="$1"
  local readonly name="$2"

  aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Name,Values=${name}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text || return 1
}

# Prints "<endpoint-address> <master-secret-arn>".
function describe_db {
  local readonly region="$1"
  local readonly db_instance="$2"

  aws rds describe-db-instances --region "$region" --db-instance-identifier "$db_instance" \
    --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text || return 1
}

# Prints the password only; the caller puts it straight into PGPASSWORD.
function read_db_password {
  local readonly region="$1"
  local readonly secret_arn="$2"
  local secret_json=""

  secret_json=$(aws secretsmanager get-secret-value --region "$region" --secret-id "$secret_arn" \
    --query SecretString --output text) || return 1
  python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' <<< "$secret_json" || return 1
}

function start_port_forward {
  local readonly region="$1"
  local readonly bastion_id="$2"
  local readonly db_host="$3"
  local readonly local_port="$4"
  local readonly session_log="$5"

  if port_is_open "$local_port"; then
    log_error "local port $local_port is already in use; pick another with --local-port"
    exit 1
  fi

  log_info "opening SSM port-forward: localhost:$local_port -> $db_host:5432 via $bastion_id"
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
  log_info "port-forward is up after ${waited}s"
}

# Prints "utc|products|movements|max_movement_id|reports|sum_quantity".
function capture_counts {
  psql -XAtc "select now() at time zone 'utc', (select count(*) from products), \
    (select count(*) from movements), (select coalesce(max(id),0) from movements), \
    (select count(*) from daily_reports), (select coalesce(sum(quantity),0) from products)" || return 1
}

function check_client_version {
  local server_major=""
  local client_major=""

  server_major=$(psql -XAtc "show server_version_num" | cut -c1-2) || return 1
  client_major=$(pg_dump --version | sed -E 's/.* ([0-9]+)\..*/\1/')
  if [[ "$client_major" -lt "$server_major" ]]; then
    log_error "pg_dump $client_major is older than the server ($server_major); install PostgreSQL $server_major client"
    exit 1
  fi
  log_info "server PostgreSQL $server_major, pg_dump $client_major"
}

function sha256_of {
  local readonly file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  else
    shasum -a 256 "$file"
  fi
}

function verify_archive {
  local readonly dump_file="$1"
  local table_count=""

  table_count=$(pg_restore --list "$dump_file" | grep -c "TABLE DATA" || true)
  if [[ "$table_count" -ne "$EXPECTED_TABLES" ]]; then
    log_error "archive lists $table_count tables with data, expected $EXPECTED_TABLES"
    exit 1
  fi
  log_info "archive is readable: $table_count tables with data"
}

function restore_check {
  local readonly dump_file="$1"
  local readonly counts_before="$2"
  local restored=""

  assert_is_installed "docker"
  RESTORE_CONTAINER="hive-restore-check-$$"
  log_info "restore check: starting $RESTORE_CONTAINER (postgres:16-alpine)"
  docker run -d --rm --name "$RESTORE_CONTAINER" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=hive \
    postgres:16-alpine >/dev/null
  until docker exec "$RESTORE_CONTAINER" pg_isready -U postgres -q; do
    sleep 1
  done
  sleep 2

  if ! docker exec -i "$RESTORE_CONTAINER" pg_restore -U postgres -d hive --no-owner \
    --no-privileges --exit-on-error < "$dump_file"; then
    log_error "pg_restore failed; the dump is NOT restorable"
    exit 1
  fi

  restored=$(docker exec "$RESTORE_CONTAINER" psql -U postgres -d hive -XAtc \
    "select (select count(*) from products), (select count(*) from movements), \
     (select coalesce(max(id),0) from movements), (select count(*) from daily_reports)")
  log_info "restored counts  : products|movements|max_id|reports = $restored"

  # Counts were taken just before pg_dump's snapshot, so the restore may hold
  # a few more rows (writes continue), never fewer.
  local readonly before_movements=$(echo "$counts_before" | cut -d'|' -f3)
  local readonly restored_movements=$(echo "$restored" | cut -d'|' -f2)
  if [[ "$restored_movements" -lt "$before_movements" ]]; then
    log_error "restore has $restored_movements movements, fewer than the $before_movements counted before the dump"
    exit 1
  fi
  log_info "restore check passed: $restored_movements movements (>= $before_movements counted before the dump)"
}

function main {
  local region="$DEFAULT_REGION"
  local db_instance="$DEFAULT_DB_INSTANCE"
  local bastion_name="$DEFAULT_BASTION_NAME"
  local local_port="$DEFAULT_LOCAL_PORT"
  local out_dir="$DEFAULT_OUT_DIR"
  local do_restore_check="false"
  local log_file_arg=""
  local no_log_file="false"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
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
      --out-dir)
        out_dir="$2"
        shift
        ;;
      --restore-check)
        do_restore_check="true"
        ;;
      --log-file)
        log_file_arg="$2"
        shift
        ;;
      --no-log-file)
        no_log_file="true"
        ;;
      --help)
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

  assert_not_empty "--region" "$region"
  assert_not_empty "--db-instance" "$db_instance"
  assert_not_empty "--bastion-name" "$bastion_name"
  assert_not_empty "--local-port" "$local_port"
  assert_not_empty "--out-dir" "$out_dir"

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
    log_info "log file    : $LOG_FILE"
  fi

  for bin in aws session-manager-plugin psql pg_dump pg_restore python3 nc; do
    assert_is_installed "$bin"
  done

  trap cleanup EXIT

  local bastion_id=""
  bastion_id=$(find_bastion "$region" "$bastion_name")
  if [[ -z "$bastion_id" || "$bastion_id" == "None" ]]; then
    log_error "no running instance tagged Name=$bastion_name in $region (is enable_bastion applied?)"
    exit 1
  fi

  local db_info=""
  db_info=$(describe_db "$region" "$db_instance")
  local readonly db_host=$(echo "$db_info" | awk '{print $1}')
  local readonly secret_arn=$(echo "$db_info" | awk '{print $2}')
  assert_not_empty "db endpoint" "$db_host"
  assert_not_empty "db master secret" "$secret_arn"
  log_info "database    : $db_instance ($db_host)"

  mkdir -p "$out_dir"
  local readonly ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local readonly base="${out_dir}/${db_instance}-${ts}"

  start_port_forward "$region" "$bastion_id" "$db_host" "$local_port" "${base}.ssm.log"

  export PGHOST=127.0.0.1 PGPORT="$local_port" PGUSER=hive PGDATABASE=hive PGSSLMODE=require
  PGPASSWORD=$(read_db_password "$region" "$secret_arn")
  export PGPASSWORD
  assert_not_empty "database password" "$PGPASSWORD"

  check_client_version

  local counts=""
  counts=$(capture_counts)
  echo "$counts" > "${base}.counts"
  log_info "counts before dump (utc|products|movements|max_id|reports|sum_qty): $counts"

  log_info "pg_dump -> ${base}.dump"
  if ! pg_dump -Fc -Z6 --no-owner --no-privileges -f "${base}.dump"; then
    log_error "pg_dump failed"
    exit 1
  fi
  sha256_of "${base}.dump" > "${base}.dump.sha256"
  log_info "sha256      : $(cut -d' ' -f1 "${base}.dump.sha256")"
  log_info "size        : $(du -h "${base}.dump" | cut -f1)"

  verify_archive "${base}.dump"

  if [[ "$do_restore_check" == "true" ]]; then
    restore_check "${base}.dump" "$counts"
  fi

  log_info "done: ${base}.dump (+ .counts, .dump.sha256). Contains customer data: keep it on an encrypted disk."
}

main "$@"
