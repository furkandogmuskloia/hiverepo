# --- build ---------------------------------------------------------------
# Graviton (arm64) node'lara ciktigi icin hedef arm64. Apple Silicon uzerinde
# native derlenir, QEMU emulasyonu yok -> build birkac saniye surer.
FROM golang:1.25-alpine AS build

WORKDIR /src

# once bagimliliklar: main.go degisince bu katman cache'ten gelir
COPY go.mod go.sum ./
RUN go mod download

COPY *.go ./

ARG TARGETARCH=arm64
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -buildvcs=false -trimpath -ldflags="-s -w" -o /out/hive .

# --- runtime -------------------------------------------------------------
# distroless/static: shell yok, paket yoneticisi yok, libc yok.
# :nonroot etiketi UID/GID 65532 ile calisir -> runAsNonRoot ile uyumlu.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/hive /hive

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/hive"]
