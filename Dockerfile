FROM alpine:3.23.3

ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache \
  bash \
  coreutils \
  curl \
  gcompat \
  gpg \
  gpg-agent \
  gpgconf \
  pigz \
  tar && \
  case "$TARGETARCH${TARGETVARIANT:+/$TARGETVARIANT}" in \
  amd64) mc_arch='amd64' ;; \
  arm/v6|arm/v7) mc_arch='arm' ;; \
  arm64|arm64/v8) mc_arch='arm64' ;; \
  ppc64le) mc_arch='ppc64le' ;; \
  *) echo "Unsupported TARGETARCH/TARGETVARIANT: $TARGETARCH${TARGETVARIANT:+/$TARGETVARIANT}" >&2; exit 1 ;; \
  esac && \
  mc_url="https://dl.min.io/client/mc/release/linux-${mc_arch}/mc" && \
  curl "$mc_url" \
  --location \
  --create-dirs \
  --output /usr/local/bin/mc && \
  curl "${mc_url}.sha256sum" \
  --location \
  --output /tmp/mc.sha256sum && \
  awk '{print $1 "  /usr/local/bin/mc"}' /tmp/mc.sha256sum | sha256sum -c - && \
  chmod +x /usr/local/bin/mc && \
  rm -f /tmp/mc.sha256sum && \
  apk del --purge curl

COPY bin/backup bin/restore bin/vb-test /usr/local/bin/
