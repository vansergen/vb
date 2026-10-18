# dl.min.io no longer serves MinIO client binaries, so build the same pinned
# release (RELEASE.2025-08-13T08-35-41Z) from source. The Go checksum database
# verifies the module contents. Cross-compiling on the build platform avoids
# running the Go toolchain under QEMU for foreign architectures.
FROM --platform=$BUILDPLATFORM golang:1.26.9-alpine3.23 AS mc

ARG TARGETOS
ARG TARGETARCH
ARG MC_MODULE_VERSION=v0.0.0-20250813083541-7394ce0dd2a8

RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
  go install -trimpath -ldflags '-s -w' "github.com/minio/mc@${MC_MODULE_VERSION}" && \
  install -D -m 0755 "$(find /go/bin -type f -name mc)" /out/mc

FROM alpine:3.23.3

RUN apk add --no-cache \
  bash \
  coreutils \
  gpg \
  gpg-agent \
  gpgconf \
  pigz \
  tar

COPY --from=mc /out/mc /usr/local/bin/mc
COPY bin/backup bin/restore bin/vb-test /usr/local/bin/
