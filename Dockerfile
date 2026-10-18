FROM alpine:3.24.2 AS base

RUN apk add --no-cache \
  attr \
  bash \
  coreutils \
  curl \
  findutils \
  flock \
  gpg \
  gpg-agent \
  gpgconf \
  pigz \
  tar \
  tini \
  zstd

COPY lib/vb/ /usr/local/lib/vb/
COPY bin/backup bin/restore /usr/local/bin/

# tini forwards signals to the whole process group (-g), so `docker stop`
# also reaches the tar/gpg/curl processes of a running backup or restore.
ENTRYPOINT ["/sbin/tini", "-g", "--"]

# Test image: test tooling and the test suite on top of the runtime image.
FROM base AS test

RUN apk add --no-cache \
  acl

COPY bin/vb-test /usr/local/bin/

# The runtime image is the last stage, so it is what a plain build produces.
FROM base AS runtime
