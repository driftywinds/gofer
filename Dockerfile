# syntax=docker/dockerfile:1

# Gofer (https://github.com/cristianadrielbraun/gofer) - self-hosted email client.
# This Dockerfile clones the upstream repo itself, so it works from an empty directory.

# ---------- build stage ----------
FROM golang:1.27-bookworm AS build

ARG GOFER_REPO=https://github.com/cristianadrielbraun/gofer.git
# Branch, tag or commit to build, e.g. master or v0.5.2
ARG GOFER_REF=master
ARG TARGETARCH
# Tailwind standalone CLI (v4). Pin by swapping "latest/download" for "download/vX.Y.Z".
ARG TAILWIND_BASE=https://github.com/tailwindlabs/tailwindcss/releases/latest/download

WORKDIR /src
RUN git clone "${GOFER_REPO}" . \
 && git checkout "${GOFER_REF}"

# templ, pinned to the version in go.mod
RUN go install github.com/a-h/templ/cmd/templ@$(go list -m -f '{{.Version}}' github.com/a-h/templ)

# Tailwind standalone binary
RUN case "${TARGETARCH:-amd64}" in \
      amd64) TW=tailwindcss-linux-x64 ;; \
      arm64) TW=tailwindcss-linux-arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/tailwindcss "${TAILWIND_BASE}/${TW}" \
 && chmod +x /usr/local/bin/tailwindcss

# Same steps as `task release`: generate views + CSS, then build with embedded assets
RUN templ generate --ignore-pattern='(^|/)(tmp|dist)(/|$)' \
 && tailwindcss -i ./assets/css/input.css -o ./assets/css/output.css --minify
RUN CGO_ENABLED=0 go build -tags embedded_assets -trimpath -ldflags="-s -w" -o /out/gofer .

# ---------- runtime stage ----------
FROM alpine:3.22

# CA certs are required for IMAP/SMTP TLS and OAuth; tzdata for correct local times
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S -g 10001 gofer \
 && adduser -S -u 10001 -G gofer -h /app gofer \
 && mkdir -p /app/data \
 && chown -R gofer:gofer /app

COPY --from=build /out/gofer /usr/local/bin/gofer

USER gofer
WORKDIR /app

# SQLite DB, cached mail, attachments and generated secrets all live under /app/data
ENV GO_ENV=production \
    GOFER_ADDR=0.0.0.0:8090 \
    GOFER_DB_PATH=/app/data/gofer.db

VOLUME ["/app/data"]
EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD nc -z 127.0.0.1 8090 || exit 1

ENTRYPOINT ["gofer"]
