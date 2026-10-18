# shellcheck shell=bash disable=SC2034,SC2154
# (state is shared with the sourcing scripts)
#
# Catalog of the backups in a local directory or an S3 prefix. Sourced after
# common.sh and s3.sh.
#
# Archives are named <volume>_<YYYYMMDD_HHMMSS>.tar[.gz|.zst][.gpg] and have
# a <archive>.sha256 checksum sidecar. A backup is complete when both exist
# and belong together:
#   - locally, the sidecar holds a valid digest and names the archive (or
#     names nothing);
#   - in S3, both objects carry the same x-amz-meta-vb-token, or neither of
#     them does (backups made before tokens existed). Without token checks
#     (catalog_scan_s3 ... 0), an existing sidecar is enough.
# Everything else is incomplete, and a sidecar without its archive is an
# orphan.

# Parallel arrays, one entry per archive (or orphaned sidecar)
declare -a cat_names=()        # archive name (for an orphan: the name its sidecar refers to)
declare -a cat_volumes=()
declare -a cat_ts=()
declare -a cat_sizes=()        # archive size in bytes (empty for an orphan)
declare -a cat_status=()       # complete | incomplete | orphan
declare -a cat_reasons=()      # why an entry is incomplete
declare -a cat_sidecars=()     # 1 if the sidecar exists
declare -a cat_locations=()    # local path or s3:// URL of the archive
declare -a cat_keys=()         # S3 key of the archive
declare -a cat_etags=()        # S3 ETag of the archive
declare -a cat_sidecar_etags=()
declare -a cat_virtual=()      # 1 for a backup that does not exist yet (dry runs)

cat_parsed_volume=""
cat_parsed_ts=""

catalog_reset() {
  cat_names=() cat_volumes=() cat_ts=() cat_sizes=() cat_status=() cat_reasons=()
  cat_sidecars=() cat_locations=() cat_keys=() cat_etags=() cat_sidecar_etags=() cat_virtual=()
}

# Parses a backup archive name; sets cat_parsed_volume and cat_parsed_ts.
catalog_parse_name() {
  local name="$1"
  cat_parsed_volume=""
  cat_parsed_ts=""

  name="${name%.gpg}"
  case "$name" in
    *.tar.gz) name="${name%.gz}" ;;
    *.tar.zst) name="${name%.zst}" ;;
  esac
  [[ "$name" == *.tar ]] || return 1
  name="${name%.tar}"

  [[ "$name" =~ ^(.+)_([0-9]{8}_[0-9]{6})$ ]] || return 1
  cat_parsed_volume="${BASH_REMATCH[1]}"
  cat_parsed_ts="${BASH_REMATCH[2]}"
}

# Prints the epoch seconds of a backup timestamp (read as UTC). Fails for
# timestamps that are not a real date and time (names only require digits).
catalog_ts_epoch() {
  local ts="$1"
  date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null
}

catalog__add() {
  # name volume ts size status reason sidecar location key etag sidecar_etag virtual
  cat_names+=("$1")
  cat_volumes+=("$2")
  cat_ts+=("$3")
  cat_sizes+=("$4")
  cat_status+=("$5")
  cat_reasons+=("$6")
  cat_sidecars+=("$7")
  cat_locations+=("$8")
  cat_keys+=("$9")
  cat_etags+=("${10}")
  cat_sidecar_etags+=("${11}")
  cat_virtual+=("${12}")
}

# Adds a backup that a dry run would create, so that plans can include it.
catalog_add_virtual() {
  local name="$1"
  catalog_parse_name "$name" || return 1
  catalog__add "$name" "$cat_parsed_volume" "$cat_parsed_ts" "" complete "" 1 "" "" "" "" 1
}

catalog__valid_name() {
  catalog_parse_name "$1" || return 1
  if ! is_valid_volume_name "$cat_parsed_volume"; then
    log WARN "Skipping backup with unsafe volume name '${cat_parsed_volume}': $1"
    return 1
  fi
}

# Checks the sidecar of a local archive. Prints the reason when the pair is
# incomplete.
catalog__local_pair_problem() {
  local sidecar="$1" name="$2" named

  [[ -f "$sidecar" ]] || {
    printf 'no checksum file\n'
    return
  }
  read_sidecar_digest "$sidecar" >/dev/null || {
    printf 'malformed checksum file\n'
    return
  }
  # "<digest>  <name>" or "<digest> *<name>"; version 1.0 wrote an absolute path
  named="$(awk 'NR == 1 { sub(/^[^ \t]+[ \t]+/, ""); sub(/^\*/, ""); print; exit }' "$sidecar")"
  if [[ -n "$named" && "${named##*/}" != "$name" ]]; then
    printf 'checksum file names %s\n' "${named##*/}"
  fi
}

catalog__local_archives() {
  find "$1" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tar.zst' \
    -o -name '*.tar.gpg' -o -name '*.tar.gz.gpg' -o -name '*.tar.zst.gpg' \) -print0
}

catalog_scan_local() {
  local dir="${1%/}" path name problem status size
  local -a paths=()
  catalog_reset
  [[ -d "$dir" ]] || die "Backup directory not found: $dir"

  vb_collect paths nul catalog__local_archives "$dir"
  for path in "${paths[@]}"; do
    name="${path##*/}"
    catalog__valid_name "$name" || continue
    problem="$(catalog__local_pair_problem "${path}.sha256" "$name")"
    status=complete
    [[ -z "$problem" ]] || status=incomplete
    size="$(stat -c %s -- "$path")" || die "Failed to read the size of ${path}"
    catalog__add "$name" "$cat_parsed_volume" "$cat_parsed_ts" "$size" "$status" "$problem" \
      "$([[ -f "${path}.sha256" ]] && echo 1 || echo 0)" "$path" "" "" "" 0
  done

  vb_collect paths nul find "$dir" -maxdepth 1 -type f -name '*.sha256' -print0
  for path in "${paths[@]}"; do
    name="${path##*/}"
    name="${name%.sha256}"
    [[ ! -e "${dir}/${name}" ]] || continue
    catalog__valid_name "$name" || continue
    catalog__add "$name" "$cat_parsed_volume" "$cat_parsed_ts" "" orphan "checksum file without its archive" 1 \
      "${dir}/${name}" "" "" "" 0
  done
}

# Lists an S3 prefix (direct children only).
#   catalog_scan_s3 <bucket> <prefix> <check-tokens: 0|1>
catalog_scan_s3() {
  local bucket="$1" prefix="$2" check_tokens="$3"
  local key size etag name status reason line
  local -a lines=()
  local -A sizes=() etags=() keys=()
  catalog_reset

  # The whole listing must succeed before anything is decided from it
  vb_collect lines line s3_list "$bucket" "$prefix"
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r key size etag <<< "$line"
    [[ -n "$key" ]] || continue
    name="${key##*/}"
    sizes[$name]="$size"
    etags[$name]="$etag"
    keys[$name]="$key"
  done

  for name in "${!keys[@]}"; do
    if [[ "$name" == *.sha256 ]]; then
      [[ -z "${keys[${name%.sha256}]:-}" ]] || continue
      catalog__valid_name "${name%.sha256}" || continue
      key="${keys[$name]%.sha256}"
      catalog__add "${name%.sha256}" "$cat_parsed_volume" "$cat_parsed_ts" "" orphan "checksum file without its archive" 1 \
        "s3://${bucket}/${key}" "$key" "" "${etags[$name]}" 0
      continue
    fi

    catalog__valid_name "$name" || continue
    key="${keys[$name]}"
    status=complete
    reason=""
    if [[ -z "${keys[${name}.sha256]:-}" ]]; then
      status=incomplete
      reason="no checksum file"
    fi
    catalog__add "$name" "$cat_parsed_volume" "$cat_parsed_ts" "${sizes[$name]}" "$status" "$reason" \
      "$([[ -n "${keys[${name}.sha256]:-}" ]] && echo 1 || echo 0)" "s3://${bucket}/${key}" "$key" \
      "${etags[$name]}" "${etags[${name}.sha256]:-}" 0
    if (( check_tokens )); then
      catalog_check_s3_tokens "$bucket" "$(( ${#cat_names[@]} - 1 ))"
    fi
  done
}

# Downgrades an S3 entry to incomplete when its archive and checksum file
# come from different uploads (their tokens differ).
#   catalog_check_s3_tokens <bucket> <index>
catalog_check_s3_tokens() {
  local bucket="$1" i="$2" token="" sidecar_token=""
  [[ "${cat_status[i]}" == complete ]] || return 0

  if s3_head "$bucket" "${cat_keys[i]}"; then
    token="$(s3__header "$s3_head_headers" x-amz-meta-vb-token)"
  fi
  if s3_head "$bucket" "${cat_keys[i]}.sha256"; then
    sidecar_token="$(s3__header "$s3_head_headers" x-amz-meta-vb-token)"
  fi
  if [[ "$token" != "$sidecar_token" ]]; then
    cat_status[i]=incomplete
    cat_reasons[i]="checksum file belongs to another upload"
  fi
}

# Prints the indices of the entries of a volume, newest first.
catalog_indices_for_volume() {
  local volume="$1" i
  for i in "${!cat_names[@]}"; do
    [[ "${cat_volumes[i]}" == "$volume" ]] || continue
    printf '%s\t%s\t%s\n' "${cat_ts[i]}" "${cat_names[i]}" "$i"
  done | LC_ALL=C sort -r | cut -f3
}

# Formats a byte count for humans.
catalog_human_size() {
  [[ -n "$1" ]] || {
    printf '%s\n' "-"
    return
  }
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i]
  }'
}
