# syntax=docker/dockerfile:1
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hive .

# statik binary, shell yok, root degil
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/hive /hive
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/hive"]
