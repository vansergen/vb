# shellcheck shell=bash disable=SC2034
# (state is shared with the sourcing scripts)
#
# Helpers shared by bin/backup and bin/restore. This file is sourced, never
# executed. The sourcing script must set SCRIPT_NAME before sourcing it.

# ------------------------------------------------------------------------------
# Colors and logging
# ------------------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly COLOR_RESET=$'\033[0m'
  readonly COLOR_RED=$'\033[0;31m'
  readonly COLOR_YELLOW=$'\033[0;33m'
  readonly COLOR_GREEN=$'\033[0;32m'
else
  readonly COLOR_RESET=""
  readonly COLOR_RED=""
  readonly COLOR_YELLOW=""
  readonly COLOR_GREEN=""
fi

log() {
  local level="INFO"
  local color="$COLOR_GREEN"

  case "${1:-}" in
    ERROR)
      level="ERROR"
      color="$COLOR_RED"
      shift
      ;;
    WARN)
      level="WARN"
      color="$COLOR_YELLOW"
      shift
      ;;
    INFO)
      level="INFO"
      color="$COLOR_GREEN"
      shift
      ;;
  esac

  printf '[%s] %s %b[%s]%b %s\n' \
    "$SCRIPT_NAME" \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$color" \
    "$level" \
    "$COLOR_RESET" \
    "$*" >&2
}

die() {
  log ERROR "$*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# ------------------------------------------------------------------------------
# Private working directory (GPG home, S3 client config, FIFOs, temp files)
# ------------------------------------------------------------------------------

work_dir=""

ensure_work_dir() {
  if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d)"
  fi
}

cleanup_work_dir() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    if [[ -n "${GNUPGHOME:-}" && "$GNUPGHOME" == "$work_dir"/* ]]; then
      gpgconf --kill all >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
  fi
}

random_hex() {
  od -An -tx1 -N "${1:-16}" /dev/urandom | tr -d ' \n'
}

# ------------------------------------------------------------------------------
# Volume names and paths
# ------------------------------------------------------------------------------

# Docker volume names must start with an alphanumeric character; this also
# rules out '.', '..' and other dot-names that would escape VOLUMES_ROOT.
readonly VOLUME_NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]*$'

volumes_root_real=""

is_valid_volume_name() {
  [[ "$1" =~ $VOLUME_NAME_RE ]]
}

validate_volume_name() {
  is_valid_volume_name "$1" || die \
    "Invalid volume name '$1': it must start with a letter or digit and contain only alphanumeric characters, dots, dashes, and underscores"
}

init_volumes_root() {
  [[ -d "$VOLUMES_ROOT" ]] || die "Volumes root not found: $VOLUMES_ROOT"
  volumes_root_real="$(realpath -e -- "$VOLUMES_ROOT")" || die "Unable to resolve volumes root: $VOLUMES_ROOT"
  [[ "$volumes_root_real" != "/" ]] || die "VOLUMES_ROOT must not be the filesystem root"
}

# Prints the canonical path of VOLUMES_ROOT/<name>. Fails unless it resolves to
# a directory that is a direct child of VOLUMES_ROOT (no symlink escapes).
resolve_volume_dir() {
  local real
  real="$(realpath -e -- "${VOLUMES_ROOT%/}/$1" 2>/dev/null)" || return 1
  [[ -d "$real" && "${real%/*}" == "$volumes_root_real" && "$real" != "$volumes_root_real" ]] || return 1
  printf '%s\n' "$real"
}

# ------------------------------------------------------------------------------
# Archive helpers
# ------------------------------------------------------------------------------

tar_extra_flags=()

prepare_tar_flags() {
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar_extra_flags=(--acls --xattrs '--xattrs-include=*' --sparse)
  fi
}

# Prints the SHA-256 digest recorded in a checksum sidecar. Accepts the
# "<digest>  <name>" and "<digest> *<name>" forms and ignores the name.
read_sidecar_digest() {
  local digest
  digest="$(awk 'NR == 1 { print $1; exit }' "$1" 2>/dev/null)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

# ------------------------------------------------------------------------------
# GPG
# ------------------------------------------------------------------------------

prepare_gpg_home() {
  ensure_work_dir
  export GNUPGHOME="${work_dir}/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  printf 'allow-loopback-pinentry\n' > "${GNUPGHOME}/gpg-agent.conf"
  gpgconf --launch gpg-agent >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Test hooks (inactive unless VB_TEST_HOOKS=1)
# ------------------------------------------------------------------------------

# Pauses at a named point so tests can interleave other actions:
#   VB_TEST_PAUSE_AT=<point>[,<point>...]  VB_TEST_PAUSE_DIR=<dir>
# On reaching a point, creates <dir>/<point>.reached and waits for
# <dir>/<point>.continue to appear.
vb_test_point() {
  [[ "${VB_TEST_HOOKS:-0}" == 1 ]] || return 0

  local point="$1"
  if [[ ",${VB_TEST_PAUSE_AT:-}," == *",${point},"* && -n "${VB_TEST_PAUSE_DIR:-}" ]]; then
    : > "${VB_TEST_PAUSE_DIR}/${point}.reached"
    while [[ ! -e "${VB_TEST_PAUSE_DIR}/${point}.continue" ]]; do
      sleep 0.1
    done
  fi
}
