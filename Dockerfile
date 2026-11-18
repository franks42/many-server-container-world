# One image = one "server": a bb app plus its tsnet sidecar process.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY tsproxy/go.mod tsproxy/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY tsproxy/ ./
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tsproxy .

FROM babashka/babashka:latest
COPY --from=build /out/tsproxy /usr/local/bin/tsproxy
COPY app/server.clj /app/server.clj
COPY scripts/node-entrypoint.sh /usr/local/bin/node-entrypoint
RUN chmod +x /usr/local/bin/node-entrypoint
ENTRYPOINT ["/usr/local/bin/node-entrypoint"]
