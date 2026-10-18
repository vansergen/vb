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

# ERR trap handler: reports the failing command of the main process (not of
# subshells, which report through their exit status).
report_unexpected_error() {
  [[ "${BASHPID:-$$}" == "$$" ]] || return 0
  log ERROR "Unexpected failure (exit $1) at line $2: $3"
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
# Lists from commands
# ------------------------------------------------------------------------------

# Stores the output of a command in an array. The command runs in the current
# shell (not in a process substitution), so `die` inside it ends the script,
# and any other failure is fatal too: a partial list is never used.
#
# The command runs with errexit off (it is called inside ||). It must report
# every failure through its exit status or die: a function either checks each
# of its steps or ends with the one pipeline whose status matters.
#   vb_collect <array> <nul|line> <command> [args...]
vb_collect() {
  local -n vb__collect_into="$1"
  local mode="$2" file rc=0
  shift 2

  if [[ -z "$work_dir" && "${BASHPID:-$$}" == "$$" ]]; then
    ensure_work_dir
  fi
  file="$(mktemp "${work_dir:-${TMPDIR:-/tmp}}/list.XXXXXX")" || die "Failed to create a temporary file"
  "$@" > "$file" || rc=$?
  if (( rc != 0 )); then
    rm -f -- "$file"
    die "Failed to list ($*): exit ${rc}"
  fi

  if [[ "$mode" == nul ]]; then
    mapfile -d '' -t vb__collect_into < "$file"
  else
    mapfile -t vb__collect_into < "$file"
  fi
  rm -f -- "$file"
}

# ------------------------------------------------------------------------------
# Archive helpers
# ------------------------------------------------------------------------------

tar_extra_flags=()
tar_extract_flags=()

# tar_extra_flags are used when creating archives, tar_extract_flags when
# extracting them. SELinux labels belong to the host, so they are never
# restored (the target's own labeling applies).
prepare_tar_flags() {
  local version
  tar_extra_flags=()
  tar_extract_flags=()
  # Captured, not piped into `grep -q`: with pipefail, tar could die of
  # SIGPIPE when grep exits early, silently dropping these flags.
  version="$(tar --version 2>/dev/null)" || true
  if [[ "$version" == *"GNU tar"* ]]; then
    tar_extra_flags=(--acls --xattrs '--xattrs-include=*' --sparse)
    tar_extract_flags=("${tar_extra_flags[@]}" '--xattrs-exclude=security.selinux')
  fi
}

# Prints the SHA-256 digest recorded in a checksum sidecar. Accepts the
# "<digest>  <name>" and "<digest> *<name>" forms and ignores the name.
# Returns 1 for malformed content; a file that cannot be read is fatal.
read_sidecar_digest() {
  local digest
  digest="$(awk 'NR == 1 { print $1; exit }' "$1")" || die "Failed to read the checksum file $1"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

# ------------------------------------------------------------------------------
# Secrets
# ------------------------------------------------------------------------------

# Docker-style secrets: for each <VAR>, a <VAR>_FILE variable names a file
# that holds the value (trailing newlines are dropped). The value is
# exported and <VAR>_FILE unset, so child processes see only <VAR>.
load_secret_files() {
  local var file_var file value
  for var in "$@"; do
    file_var="${var}_FILE"
    [[ -n "${!file_var:-}" ]] || continue
    [[ -z "${!var:-}" ]] || die "Both ${var} and ${file_var} are set; set only one of them"
    file="${!file_var}"
    [[ -f "$file" && -r "$file" ]] || die "${file_var} does not name a readable file: ${file}"
    value="$(< "$file")"
    printf -v "$var" '%s' "$value"
    export "${var?}"
    unset "$file_var"
  done
}

# ------------------------------------------------------------------------------
# GPG
# ------------------------------------------------------------------------------

# GPG reads a passphrase from a file descriptor up to the first newline.
# Warns once per process.
check_passphrase_newline() {
  [[ "$1" == *$'\n'* && -z "${vb_passphrase_warned:-}" ]] || return 0
  vb_passphrase_warned=1
  log WARN "GPG_PASSPHRASE contains a newline; GPG uses only the text before the first newline as the passphrase"
}

prepare_gpg_home() {
  ensure_work_dir
  export GNUPGHOME="${work_dir}/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  printf 'allow-loopback-pinentry\n' > "${GNUPGHOME}/gpg-agent.conf"
  gpgconf --launch gpg-agent >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Processes
# ------------------------------------------------------------------------------

# Prints the PIDs of a process and all of its descendants.
process_tree_pids() {
  local root="$1" stat_file content pid ppid current
  local -A children=()

  for stat_file in /proc/[0-9]*/stat; do
    content="$(cat "$stat_file" 2>/dev/null)" || continue
    pid="${content%% *}"
    content="${content##*) }"
    ppid="${content#* }"
    ppid="${ppid%% *}"
    children[$ppid]+=" $pid"
  done

  local -a queue=("$root")
  while (( ${#queue[@]} > 0 )); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    printf '%s\n' "$current"
    for pid in ${children[$current]:-}; do
      queue+=("$pid")
    done
  done
}

# Waits until at least one of the given child processes has exited, without
# polling: `wait -n` wakes up on any exit (and on trapped signals), then the
# exit status of every finished child is collected. Fills vb_done_pids and
# vb_done_status (parallel arrays).
vb_wait_any() {
  local pid status
  vb_done_pids=()
  vb_done_status=()

  while :; do
    for pid in "$@"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        status=0
        wait "$pid" || status=$?
        vb_done_pids+=("$pid")
        vb_done_status+=("$status")
      fi
    done
    (( ${#vb_done_pids[@]} == 0 )) || return 0
    status=0
    wait -n 2>/dev/null || status=$?
    # 127: no job left to wait for (should not happen); avoid spinning
    if (( status == 127 )); then
      sleep 0.2
    fi
  done
}

# Sends a signal to a process and all of its descendants, then waits (up to
# about 30 seconds) until none of them is left.
stop_process_tree() {
  local root="$1" signal="${2:-TERM}" pid i
  local -a pids=()

  mapfile -t pids < <(process_tree_pids "$root")
  for pid in "${pids[@]}"; do
    kill "-${signal}" "$pid" 2>/dev/null || true
  done

  for (( i = 0; i < 300; i++ )); do
    local alive=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null && [[ "$(cut -d' ' -f3 "/proc/${pid}/stat" 2>/dev/null)" != Z ]]; then
        alive=1
        break
      fi
    done
    (( alive )) || break
    sleep 0.1
  done
  wait "$root" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Mounts
# ------------------------------------------------------------------------------

# Prints the mount points (from /proc/self/mountinfo) strictly below a path.
# Returns non-zero when the mount table cannot be read: never "no mounts".
mounts_below() {
  local base="${1%/}" mountinfo=/proc/self/mountinfo
  if [[ "${VB_TEST_HOOKS:-0}" == 1 && -n "${VB_TEST_MOUNTINFO:-}" ]]; then
    mountinfo="$VB_TEST_MOUNTINFO"
  fi
  [[ -r "$mountinfo" ]] || return 1
  awk '{ print $5 }' "$mountinfo" | while IFS= read -r point; do
    point="$(printf '%b' "${point//\\/\\0}")"
    if [[ "$point" == "$base"/* ]]; then
      printf '%s\n' "$point"
    fi
  done
}

# ------------------------------------------------------------------------------
# Test hooks (inactive unless VB_TEST_HOOKS=1)
# ------------------------------------------------------------------------------

if [[ "${VB_TEST_HOOKS:-0}" == 1 ]]; then
  export VB_TEST_ROOT_PID="${VB_TEST_ROOT_PID:-$$}"
fi

# Named points where tests can pause or crash a run. A point matches an entry
# "<point>" or "<point>:<volume>" of the comma-separated lists:
#   VB_TEST_PAUSE_AT  create <dir>/<entry>.reached in VB_TEST_PAUSE_DIR and
#                     wait for <dir>/<entry>.continue
#   VB_TEST_FAIL_AT   kill the whole run (the top-level script and all of
#                     its descendants) with SIGKILL, like a crash
vb_test_point() {
  [[ "${VB_TEST_HOOKS:-0}" == 1 ]] || return 0

  local point="$1" volume="${2:-}" entry
  for entry in "$point" ${volume:+"${point}:${volume}"}; do
    if [[ ",${VB_TEST_FAIL_AT:-}," == *",${entry},"* ]]; then
      vb__crash
    fi
    if [[ ",${VB_TEST_PAUSE_AT:-}," == *",${entry},"* && -n "${VB_TEST_PAUSE_DIR:-}" ]]; then
      : > "${VB_TEST_PAUSE_DIR}/${entry}.reached"
      while [[ ! -e "${VB_TEST_PAUSE_DIR}/${entry}.continue" ]]; do
        sleep 0.1
      done
    fi
  done
}

# Fills vb__tree with the PIDs of a process and its descendants without
# forking (a fork would add a process to the tree being collected).
vb__collect_tree() {
  local root="$1" stat_file content pid ppid current i
  local -A children=()

  for stat_file in /proc/[0-9]*/stat; do
    { read -r content < "$stat_file"; } 2>/dev/null || continue
    pid="${content%% *}"
    content="${content##*) }"
    ppid="${content#* }"
    ppid="${ppid%% *}"
    children[$ppid]+=" $pid"
  done

  vb__tree=("$root")
  for (( i = 0; i < ${#vb__tree[@]}; i++ )); do
    current="${vb__tree[i]}"
    for pid in ${children[$current]:-}; do
      vb__tree+=("$pid")
    done
  done
}

# Simulates a crash of the whole run: stops every process of the tree until
# no new one appears (so nothing forked meanwhile survives with inherited
# locks), then kills them all and finally itself.
vb__crash() {
  local root="${VB_TEST_ROOT_PID:-$$}" pid changed=1
  local -A stopped=()
  local -a vb__tree=()

  while (( changed )); do
    changed=0
    vb__collect_tree "$root"
    for pid in "${vb__tree[@]}"; do
      [[ "$pid" != "$BASHPID" && -z "${stopped[$pid]:-}" ]] || continue
      stopped[$pid]=1
      changed=1
      kill -STOP "$pid" 2>/dev/null || true
    done
  done

  for pid in "${!stopped[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  kill -KILL "$BASHPID"
}
