# shellcheck shell=bash disable=SC2034,SC2154
# (state is shared with the sourcing scripts)
#
# Crash-safe restore transactions. Sourced after common.sh.
#
# Each target volume gets a journal directory, $target/.vb-restore, on the
# same filesystem as the volume. The new data is extracted into journal/new,
# the old top-level entries are renamed into journal/old, then the new ones
# are renamed into place. Old data is only deleted after the whole group of
# volumes has been switched and the coordinator recorded its commit decision.
#
# Write-ahead rule: a phase is made durable before its first operation, and
# the directories it touched are synced before the next phase is recorded.
# The recorded phase therefore never runs ahead of the renames on disk, and
# every phase and rollback step is idempotent.
#
# Every operation checks its own result and dies on failure instead of
# relying on errexit, which is off inside conditions such as
# `if ! ( abort_transaction )`. A failed step therefore always leaves the
# journal in place for recovery.

readonly TXN_NAME=".vb-restore"
readonly TXN_SIGNATURE="vb-restore-journal v1"
readonly TXN_GID_RE='^[0-9a-f]{32}$'
readonly TXN_MARKER_XATTR="user.vb-restore.mtime"

declare -gA txn_lock_fds=()

# ------------------------------------------------------------------------------
# Durable file helpers
# ------------------------------------------------------------------------------

txn_sync() {
  sync -- "$@" || die "Failed to sync $*"
}

txn_mv() {
  mv -T -- "$1" "$2" || die "Failed to move $1 to $2"
}

# Writes <content> to <dir>/<name> atomically and durably.
txn_write() {
  local dir="$1" name="$2" content="$3"
  local tmp="${dir}/.${name}.tmp"

  printf '%s\n' "$content" > "$tmp" || die "Failed to write $tmp"
  txn_sync "$tmp"
  mv -f -- "$tmp" "${dir}/${name}" || die "Failed to rename $tmp"
  txn_sync "$dir"
}

txn_value() {
  [[ -f "$1" ]] || return 1
  sed -n "s/^$2=//p" "$1" | head -n 1
}

txn_state() {
  local state
  state="$(head -n 1 "$1/state" 2>/dev/null)" || return 1
  printf '%s\n' "$state"
}

# Prints the group id recorded in <dir>/VB-JOURNAL if the signature is valid.
txn_signature_gid() {
  local file="$1/VB-JOURNAL" gid
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(head -n 1 "$file")" == "$TXN_SIGNATURE" ]] || return 1
  gid="$(sed -n 's/^gid=//p' "$file" | head -n 1)"
  [[ "$gid" =~ $TXN_GID_RE ]] || return 1
  printf '%s\n' "$gid"
}

# Returns 0 if <dir> is empty and 1 if it is not. A directory that cannot be
# read is fatal, never "empty".
txn_dir_is_empty() {
  local first
  first="$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" || die "Failed to read the directory $1"
  [[ -z "$first" ]]
}

# Prints the NUL-separated names of the top-level entries of <dir>,
# excluding the journal itself.
txn_entries() {
  find "$1" -mindepth 1 -maxdepth 1 ! -name "$TXN_NAME" -printf '%f\0'
}

# ------------------------------------------------------------------------------
# Reserved names
# ------------------------------------------------------------------------------

# Classifies a reserved top-level entry of a volume. Prints:
#   journal <gid>   a working journal
#   trash <gid>     a finished journal awaiting cleanup
#   empty           an empty trash or creation directory (only rmdir it)
#   creating <gid>  an unfinished journal creation directory
#   legacy          a staging directory of an older version
#   unknown         anything else (never touched automatically)
txn_classify() {
  local target="$1" name="$2"
  local path="${target}/${name}" gid suffix

  if [[ -L "$path" || ! -d "$path" ]]; then
    printf 'unknown\n'
    return
  fi

  case "$name" in
    "$TXN_NAME")
      if gid="$(txn_signature_gid "$path")"; then
        printf 'journal %s\n' "$gid"
      else
        printf 'unknown\n'
      fi
      ;;
    "${TXN_NAME}.done."* | "${TXN_NAME}.aborted."* | "${TXN_NAME}.new."*)
      suffix="${name##*.}"
      if [[ ! "$suffix" =~ $TXN_GID_RE ]]; then
        printf 'unknown\n'
      elif txn_dir_is_empty "$path"; then
        printf 'empty\n'
      elif gid="$(txn_signature_gid "$path")" && [[ "$gid" == "$suffix" ]]; then
        if [[ "$name" == "${TXN_NAME}.new."* ]]; then
          printf 'creating %s\n' "$gid"
        else
          printf 'trash %s\n' "$gid"
        fi
      elif [[ "$name" == "${TXN_NAME}.new."* ]] && txn__only_signature_files "$path"; then
        # Interrupted while writing the signature: nothing else was written
        printf 'creating %s\n' "$suffix"
      else
        printf 'unknown\n'
      fi
      ;;
    .restore-in-progress.*)
      printf 'legacy\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

txn__only_signature_files() {
  local name
  while IFS= read -r -d '' name; do
    [[ "$name" == VB-JOURNAL || "$name" == .VB-JOURNAL.tmp ]] || return 1
  done < <(find "$1" -mindepth 1 -maxdepth 1 -printf '%f\0')
}

# Prints "<name>" for every reserved top-level entry of a volume.
txn_reserved_entries() {
  find "$1" -mindepth 1 -maxdepth 1 \( -name "${TXN_NAME}*" -o -name '.restore-in-progress.*' \) -printf '%f\n'
}

# Reads the root mtime marker of <dir> into txn_marker_value. Returns 1 when
# there is none (or user xattrs are not available); other errors are fatal.
txn_read_marker() {
  local out
  txn_marker_value=""
  command -v getfattr >/dev/null 2>&1 || return 1

  if out="$(LC_ALL=C getfattr --only-values --absolute-names -n "$TXN_MARKER_XATTR" -- "$1" 2>&1)"; then
    txn_marker_value="$out"
    return 0
  fi
  if txn__no_attribute "$out" || txn__xattr_unsupported "$out"; then
    return 1
  fi
  die "Failed to read ${TXN_MARKER_XATTR} of $1: ${out}"
}

# Describes why a volume cannot be used as a restore target or backup source
# (prints nothing when it holds no reserved entries and no marker).
txn_describe_reserved() {
  local target="$1" name class
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    class="$(txn_classify "$target" "$name")"
    printf '%s: %s\n' "$name" "${class%% *}"
  done < <(txn_reserved_entries "$target")

  if txn_read_marker "$target"; then
    printf '%s: pending root mtime marker\n' "$TXN_MARKER_XATTR"
  fi
}

# ------------------------------------------------------------------------------
# Locks
# ------------------------------------------------------------------------------

# Takes a lock on the inode of each directory (sorted, non-blocking). The
# inode of a volume root is never deleted, so the lock cannot be bypassed by
# recreating a file. Children inherit the descriptors and share the lock.
#   txn_lock <x|s> <dir>...
txn_lock() {
  local mode="$1" path fd rc
  shift

  while IFS= read -r path; do
    [[ -n "$path" && -z "${txn_lock_fds[$path]:-}" ]] || continue

    exec {fd}<"$path"
    rc=0
    flock "-${mode}" -n "$fd" || rc=$?

    if (( rc != 0 )); then
      exec {fd}<&-
      if (( rc == 1 )); then
        die "Another backup or restore is using ${path}; try again later"
      fi
      die "Unable to lock ${path} (flock exit ${rc}); the filesystem may not support locking"
    fi

    txn_lock_fds[$path]="$fd"
  done < <(printf '%s\n' "$@" | sort -u)
}

# ------------------------------------------------------------------------------
# Root metadata marker
# ------------------------------------------------------------------------------

# The marker keeps the final mtime of a volume root across a crash. Without
# user xattrs (no tools, or a filesystem that does not support them) restores
# work without it, and after a crash only the root mtime may differ. On a
# filesystem that supports them, a failure is an error like any other.
txn__xattr_unsupported() {
  [[ "$1" == *"Operation not supported"* || "$1" == *"Not supported"* ]]
}

txn__no_attribute() {
  [[ "$1" == *"No such attribute"* || "$1" == *"No data available"* ]]
}

txn__warn_no_xattr() {
  [[ -z "${txn_xattr_warned:-}" ]] || return 0
  txn_xattr_warned=1
  log WARN "User extended attributes are not available; after a crash, the mtime of a volume root may not be restored${1:+ ($1)}"
}

txn_set_marker() {
  local target="$1" value="$2" err
  if ! command -v setfattr >/dev/null 2>&1; then
    txn__warn_no_xattr "setfattr is not installed"
    return 0
  fi
  if ! err="$(LC_ALL=C setfattr -n "$TXN_MARKER_XATTR" -v "$value" -- "$target" 2>&1)"; then
    if txn__xattr_unsupported "$err"; then
      txn__warn_no_xattr "$err"
      return 0
    fi
    die "Failed to set ${TXN_MARKER_XATTR} on ${target}: ${err}"
  fi
}

txn_apply_marker() {
  local target="$1" mtime="$2" err
  touch -m -d "@${mtime}" -- "$target" || die "Failed to set the mtime of ${target}"
  if command -v setfattr >/dev/null 2>&1 \
    && ! err="$(LC_ALL=C setfattr -x "$TXN_MARKER_XATTR" -- "$target" 2>&1)" \
    && ! txn__no_attribute "$err" && ! txn__xattr_unsupported "$err"; then
    die "Failed to remove ${TXN_MARKER_XATTR} from ${target}: ${err}"
  fi
  txn_sync "$target"
}

# ------------------------------------------------------------------------------
# Phases of one participant
# ------------------------------------------------------------------------------

# Creates the journal atomically (built under a temporary reserved name, then
# renamed) and records the phase "staging".
#   txn_create <target> <gid> <volume> <coordinator> <participant>...
txn_create() {
  local target="$1" gid="$2" volume="$3" coordinator="$4"
  shift 4
  local creating="${target}/${TXN_NAME}.new.${gid}"
  local journal="${target}/${TXN_NAME}"
  local original_mtime

  original_mtime="$(date -r "$target" +%s.%N)" || die "Failed to read the mtime of ${target}"

  # Lets recovery restore the root mtime even if only a creation directory
  # was left behind
  txn_set_marker "$target" "$original_mtime"
  txn_sync "$target"

  mkdir -- "$creating" || die "Failed to create $creating"
  txn_write "$creating" VB-JOURNAL "$(printf '%s\ngid=%s' "$TXN_SIGNATURE" "$gid")"
  txn_write "$creating" group "$(printf 'gid=%s\nvolume=%s\ncoordinator=%s\nparticipants=%s\noriginal_mtime=%s' \
    "$gid" "$volume" "$coordinator" "$*" "$original_mtime")"
  txn_write "$creating" state staging
  mkdir -- "${creating}/new" "${creating}/old" || die "Failed to create the journal in $creating"
  txn_sync "$creating"

  vb_test_point "txn_create_rename" "${target##*/}"
  txn_mv "$creating" "$journal"
  txn_sync "$target"
}

# Completes staging once the archive was extracted into journal/new and
# verified: captures the root metadata, makes the data durable and records
# the phase "staged".
txn_stage_complete() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    die "The archive contains the reserved name '${name}' at its root; refusing to restore it"
  done < <(txn_reserved_entries "${journal}/new")

  date -r "${journal}/new" +%s.%N > "${journal}/root.mtime" || die "Failed to record the root mtime of ${target}"
  tar --create --no-recursion --numeric-owner "${tar_extra_flags[@]}" \
    --file "${journal}/root.tar" --directory "${journal}/new" . || die "Failed to record the root metadata of ${target}"
  txn_sync "${journal}/root.mtime" "${journal}/root.tar"

  # Make every extracted file durable before the switch can begin
  sync -f -- "$target" || die "Failed to sync the filesystem of ${target}"
  txn_write "$journal" state staged
  vb_test_point "txn_staged" "${target##*/}"
}

txn_aside() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local name
  local -a names=()

  txn_write "$journal" state aside
  vb_test_point "txn_aside" "${target##*/}"
  mapfile -d '' -t names < <(txn_entries "$target")
  for name in "${names[@]}"; do
    txn_mv "${target}/${name}" "${journal}/old/${name}"
    vb_test_point "txn_aside_entry" "${target##*/}"
  done
  txn_sync "$target" "${journal}/old"
}

txn_swap() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local name
  local -a names=()

  txn_write "$journal" state swap
  vb_test_point "txn_swap" "${target##*/}"
  mapfile -d '' -t names < <(find "${journal}/new" -mindepth 1 -maxdepth 1 -printf '%f\0')
  for name in "${names[@]}"; do
    txn_mv "${journal}/new/${name}" "${target}/${name}"
    vb_test_point "txn_swap_entry" "${target##*/}"
  done
  txn_sync "$target" "${journal}/new"
  txn_write "$journal" state swapped
}

txn__rb1() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local name
  local -a names=()

  mapfile -d '' -t names < <(txn_entries "$target")
  for name in "${names[@]}"; do
    txn_mv "${target}/${name}" "${journal}/new/${name}"
    vb_test_point "txn_rb1_entry" "${target##*/}"
  done
  txn_sync "$target" "${journal}/new"
}

txn__rb2() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local name
  local -a names=()

  mapfile -d '' -t names < <(find "${journal}/old" -mindepth 1 -maxdepth 1 -printf '%f\0')
  for name in "${names[@]}"; do
    txn_mv "${journal}/old/${name}" "${target}/${name}"
    vb_test_point "txn_rb2_entry" "${target##*/}"
  done
  txn_sync "$target" "${journal}/old"
}

# Restores the original data of one participant, following the recovery
# table: the recorded phase alone decides what to do, and an interrupted
# rb2 is continued without ever running rb1 again.
txn_rollback() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local state

  state="$(txn_state "$journal")" || die "Journal state of ${target} is unreadable; refusing to touch it"

  case "$state" in
    staging | staged)
      txn_dir_is_empty "${journal}/old" || die \
        "Journal of ${target} is in phase '${state}' but holds old data; refusing to touch it"
      ;;
    aside)
      txn_write "$journal" state rb2
      txn__rb2 "$target"
      ;;
    swap | swapped | rb1)
      [[ "$state" == rb1 ]] || txn_write "$journal" state rb1
      txn__rb1 "$target"
      txn_write "$journal" state rb2
      txn__rb2 "$target"
      ;;
    rb2)
      txn__rb2 "$target"
      ;;
    *)
      die "Journal of ${target} is in unexpected phase '${state}'; refusing to touch it"
      ;;
  esac
}

# Moves a finished journal out of the working name in one atomic rename and
# cleans it up. Interrupted cleanup leaves a trash directory, never something
# that could be mistaken for an unfinished transaction.
#   txn_retire <target> <done|aborted>
txn_retire() {
  local target="$1" kind="$2"
  local journal="${target}/${TXN_NAME}" gid trash

  gid="$(txn_signature_gid "$journal")" || die "Journal of ${target} lost its signature"
  trash="${target}/${TXN_NAME}.${kind}.${gid}"

  vb_test_point "txn_retire_${kind}" "${target##*/}"
  txn_mv "$journal" "$trash"
  txn_sync "$target"
  txn_cleanup_trash "$trash"
}

# Deletes a trash directory while keeping it identifiable to the end: the
# signature goes last, and without it only an empty directory remains.
txn_cleanup_trash() {
  local trash="$1"
  [[ -d "$trash" ]] || return 0

  if [[ -e "${trash}/VB-JOURNAL" ]]; then
    find "$trash" -mindepth 1 -maxdepth 1 ! -name VB-JOURNAL -exec rm -rf -- {} + \
      || die "Failed to delete the contents of $trash"
    txn_sync "$trash"
    vb_test_point "txn_trash_signature" "$(basename -- "$(dirname -- "$trash")")"
    rm -f -- "${trash}/VB-JOURNAL" || die "Failed to delete ${trash}/VB-JOURNAL"
  else
    rm -f -- "${trash}/.VB-JOURNAL.tmp" || die "Failed to delete ${trash}/.VB-JOURNAL.tmp"
  fi
  vb_test_point "txn_trash_rmdir" "$(basename -- "$(dirname -- "$trash")")"
  rmdir -- "$trash" || die "Failed to delete $trash"
}

# Completes one participant after the group's commit decision.
txn_finalize() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local mtime state

  # Every new entry must have been switched into place before the leftovers
  # of journal/new are deleted (once finalize began, they may be gone)
  state="$(txn_state "$journal")" || die "Journal state of ${target} is unreadable; refusing to touch it"
  if [[ "$state" != finalize && -d "${journal}/new" ]] && ! txn_dir_is_empty "${journal}/new"; then
    die "Journal of ${target} still holds new data in ${journal}/new; refusing to finalize it"
  fi

  txn_write "$journal" state finalize
  vb_test_point "txn_finalize" "${target##*/}"

  rm -rf -- "${journal}/old" "${journal}/new" || die "Failed to delete the old data in ${journal}"
  txn_sync "$journal"

  tar --extract --no-recursion --numeric-owner --same-owner --preserve-permissions \
    "${tar_extract_flags[@]}" --file "${journal}/root.tar" --directory "$target" . \
    || die "Failed to restore the root metadata of ${target}"
  mtime="$(head -n 1 "${journal}/root.mtime")" && [[ -n "$mtime" ]] \
    || die "Failed to read ${journal}/root.mtime"
  txn_set_marker "$target" "$mtime"
  txn_sync "$target"

  txn_retire "$target" "done"
  vb_test_point "txn_finalize_mtime" "${target##*/}"
  txn_apply_marker "$target" "$mtime"
}

# Rolls back one participant and retires its journal, restoring the original
# mtime of the volume root.
txn_abort_participant() {
  local target="$1"
  local journal="${target}/${TXN_NAME}"
  local mtime

  txn_rollback "$target"
  # Only an empty journal/old proves that every original entry is back
  txn_dir_is_empty "${journal}/old" || die \
    "Original data of ${target} is still in ${journal}/old after the rollback; keeping the journal. Run restore -X"
  mtime="$(txn_value "${journal}/group" original_mtime)" || mtime=""
  if [[ -n "$mtime" ]]; then
    txn_set_marker "$target" "$mtime"
    txn_sync "$target"
  fi
  txn_retire "$target" aborted
  if [[ -n "$mtime" ]]; then
    txn_apply_marker "$target" "$mtime"
  fi
}

# ------------------------------------------------------------------------------
# Groups
# ------------------------------------------------------------------------------

txn_coordinator_decided() {
  [[ "$(head -n 1 "$1/${TXN_NAME}/decision" 2>/dev/null)" == commit ]]
}

# Aborts a group: every ordinary participant first, the coordinator last.
#   txn_abort_group <coordinator-path> <participant-path>...
txn_abort_group() {
  local coordinator="$1" path
  shift

  for path in "$@"; do
    [[ "$path" != "$coordinator" && -d "${path}/${TXN_NAME}" ]] || continue
    txn_abort_participant "$path"
  done
  if [[ -d "${coordinator}/${TXN_NAME}" ]]; then
    txn_abort_participant "$coordinator"
  fi
}

# Finalizes a group: every ordinary participant first, the coordinator (whose
# journal holds the decision) last.
txn_finalize_group() {
  local coordinator="$1" path state
  shift

  for path in "$@"; do
    [[ "$path" != "$coordinator" && -d "${path}/${TXN_NAME}" ]] || continue
    state="$(txn_state "${path}/${TXN_NAME}")" || state=""
    [[ "$state" == swapped || "$state" == finalize ]] || die \
      "Journal of ${path} is in phase '${state}' although the group was committed; refusing to touch it"
    txn_finalize "$path"
  done
  if [[ -d "${coordinator}/${TXN_NAME}" ]]; then
    txn_finalize "$coordinator"
  fi
}

# ------------------------------------------------------------------------------
# Recovery
# ------------------------------------------------------------------------------

# Brings the given volumes (names; all mounted volumes when none are given)
# back to a consistent state. Nothing is changed before the locks of every
# involved volume are held, and decisions are based on a second scan taken
# under those locks.
txn_recover() {
  local -a names=("$@")
  local -A involved=()
  local name path entry class gid participants member

  if (( ${#names[@]} == 0 )); then
    mapfile -t names < <(find "$volumes_root_real" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  fi

  # 1. Detect, read-only
  for name in "${names[@]}"; do
    is_valid_volume_name "$name" || continue
    path="$(resolve_volume_dir "$name")" || continue
    if [[ -n "$(txn_describe_reserved "$path")" ]]; then
      involved[$name]=1
    fi
    if [[ -d "${path}/${TXN_NAME}" ]]; then
      participants="$(txn_value "${path}/${TXN_NAME}/group" participants)" || participants=""
      for member in $participants; do
        involved[$member]=1
      done
    fi
  done

  (( ${#involved[@]} > 0 )) || return 0

  # 2. Lock every involved volume; all of them must be mounted
  local -a paths=()
  for name in "${!involved[@]}"; do
    is_valid_volume_name "$name" || die "Journal names an invalid volume '${name}'"
    path="$(resolve_volume_dir "$name")" || die \
      "Volume '${name}' takes part in an unfinished restore but is not mounted into ${VOLUMES_ROOT}; mount all of its volumes and run restore -X"
    paths+=("$path")
  done
  txn_lock x "${paths[@]}"

  # 3. Re-scan under the locks and 4. act
  local -A groups=()
  local -A unknown=()
  for name in "${!involved[@]}"; do
    path="$(resolve_volume_dir "$name")"
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      class="$(txn_classify "$path" "$entry")"
      case "${class%% *}" in
        journal)
          gid="${class#* }"
          groups[$gid]=1
          ;;
        trash | empty | creating) ;;
        legacy)
          unknown["${path}/${entry}"]="a staging directory left by an older version (it may hold the only copy of data from an interrupted restore)"
          ;;
        *)
          unknown["${path}/${entry}"]="not created by this tool"
          ;;
      esac
    done < <(txn_reserved_entries "$path")
  done

  if (( ${#unknown[@]} > 0 )); then
    for entry in "${!unknown[@]}"; do
      log ERROR "Reserved name in use: ${entry} (${unknown[$entry]})"
    done
    die "Refusing to touch volumes with unrecognized reserved entries; inspect and move them away manually"
  fi

  for gid in "${!groups[@]}"; do
    txn__recover_group "$gid" "${!involved[@]}"
  done

  # Leftover trash, creation directories and markers
  for name in "${!involved[@]}"; do
    path="$(resolve_volume_dir "$name")"
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      class="$(txn_classify "$path" "$entry")"
      case "${class%% *}" in
        trash | creating) txn_cleanup_trash "${path}/${entry}" ;;
        empty) rmdir -- "${path}/${entry}" || die "Failed to delete ${path}/${entry}" ;;
      esac
    done < <(txn_reserved_entries "$path")
    txn_sync "$path"

    if txn_read_marker "$path" && [[ -n "$txn_marker_value" ]]; then
      txn_apply_marker "$path" "$txn_marker_value"
    fi
  done
}

txn__recover_group() {
  local gid="$1"
  shift
  local name path coordinator="" coordinator_path participants member
  local -a member_paths=()

  for name in "$@"; do
    path="$(resolve_volume_dir "$name")"
    if [[ -d "${path}/${TXN_NAME}" && "$(txn_signature_gid "${path}/${TXN_NAME}")" == "$gid" ]]; then
      coordinator="$(txn_value "${path}/${TXN_NAME}/group" coordinator)"
      participants="$(txn_value "${path}/${TXN_NAME}/group" participants)"
      break
    fi
  done

  [[ -n "$coordinator" ]] || return 0

  for member in $participants; do
    member_paths+=("$(resolve_volume_dir "$member")")
  done
  coordinator_path="$(resolve_volume_dir "$coordinator")"

  if [[ ! -d "${coordinator_path}/${TXN_NAME}" || "$(txn_signature_gid "${coordinator_path}/${TXN_NAME}")" != "$gid" ]]; then
    die "Restore group ${gid} is inconsistent: participants still have journals but the coordinator '${coordinator}' does not; refusing to touch it"
  fi

  if txn_coordinator_decided "$coordinator_path"; then
    log WARN "Completing interrupted restore of: ${participants}"
    txn_finalize_group "$coordinator_path" "${member_paths[@]}"
  else
    log WARN "Rolling back interrupted restore of: ${participants}"
    txn_abort_group "$coordinator_path" "${member_paths[@]}"
  fi
}
