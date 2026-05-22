FROM alpine:3.23.3

ARG TARGETARCH
ARG TARGETVARIANT
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z

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
  amd64)        mc_arch='amd64';   mc_sha256='01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891' ;; \
  arm64|arm64/v8) mc_arch='arm64'; mc_sha256='14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c' ;; \
  ppc64le)      mc_arch='ppc64le'; mc_sha256='0cf8776e6e1b1e2cd8a5c9e43ab26a1e2fbe57f57f51c9d99accaee3b0a2152b' ;; \
  *) echo "Unsupported TARGETARCH/TARGETVARIANT: $TARGETARCH${TARGETVARIANT:+/$TARGETVARIANT}" >&2; exit 1 ;; \
  esac && \
  mc_url="https://dl.min.io/client/mc/release/linux-${mc_arch}/archive/mc.${MC_VERSION}" && \
  curl "$mc_url" \
  --location \
  --create-dirs \
  --output /usr/local/bin/mc && \
  printf '%s  /usr/local/bin/mc\n' "$mc_sha256" | sha256sum -c - && \
  chmod +x /usr/local/bin/mc && \
  apk del --purge curl

COPY bin/backup bin/restore bin/vb-test /usr/local/bin/
