# shellcheck shell=bash disable=SC2034,SC2154
# (state is shared with the sourcing scripts)
#
# Minimal S3 client built on `curl --aws-sigv4`. Sourced after common.sh.
#
# Uploads are streamed as multipart uploads with fixed-size parts, so the
# stream length never has to be known in advance. Objects are published with
# `If-None-Match: *`, so an existing recovery point is never overwritten, and
# an upload only becomes visible when CompleteMultipartUpload succeeds.

s3_region=""
s3_scheme=""
s3_host=""
s3_style=""
s3_curl_config=""
s3_part_mb=64
s3_allow_unconditional=0
s3_head_headers=""

s3_mp_bucket=""
s3_mp_key=""
s3_mp_url=""
s3_mp_token=""
s3_mp_upload_id=""
s3_mp_upload_id_enc=""
s3_mp_parts_file=""

S3_STATUS=""
S3_CURL_RC=0

readonly S3_KEY_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

s3_validate_bucket() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "Invalid S3 bucket name: '$1'"
}

# Keys and prefixes are limited to path segments of [A-Za-z0-9._-]+ without
# '.' or '..' segments: curl would otherwise normalize them and the request
# would touch a different key than the one that was checked.
s3_key_is_safe() {
  [[ "$1" =~ $S3_KEY_RE && "/$1/" != */./* && "/$1/" != */../* ]]
}

s3_validate_key() {
  s3_key_is_safe "$1" || die \
    "Invalid S3 key '$1': use path segments of letters, digits, '.', '_' and '-' without empty, '.' or '..' segments"
}

# Prints the prefix without leading and trailing slashes, or dies.
s3_normalize_prefix() {
  local prefix="$1"
  prefix="${prefix#/}"
  prefix="${prefix%/}"

  if [[ -n "$prefix" ]]; then
    s3_key_is_safe "$prefix" || die \
      "Invalid S3 folder '$1': use path segments of letters, digits, '.', '_' and '-' without empty, '.' or '..' segments"
  fi

  printf '%s\n' "$prefix"
}

s3_parse_part_size() {
  local value="${S3_PART_SIZE:-64}"
  value="${value%MiB}"
  value="${value%M}"

  if [[ ! "$value" =~ ^[0-9]{1,4}$ ]] || (( 10#$value < 5 || 10#$value > 5120 )); then
    die "Invalid S3_PART_SIZE: '${S3_PART_SIZE}'. Expected a size in MiB from 5 to 5120 (for example 64 or 64M)"
  fi

  s3_part_mb=$((10#$value))
}

# ------------------------------------------------------------------------------
# Client setup
# ------------------------------------------------------------------------------

s3__config_quote() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

s3__urlencode() {
  local LC_ALL=C
  local input="$1" output="" char hex i
  for (( i = 0; i < ${#input}; i++ )); do
    char="${input:i:1}"
    case "$char" in
      [A-Za-z0-9._~-]) output+="$char" ;;
      *)
        printf -v hex '%%%02X' "'$char"
        output+="$hex"
        ;;
    esac
  done
  printf '%s' "$output"
}

# Asks AWS which region a bucket lives in. The answer comes back in the
# x-amz-bucket-region header even for unauthenticated requests.
s3__detect_aws_region() {
  local region
  region="$(
    curl --silent --head --max-time 15 "https://s3.amazonaws.com/$1" 2>/dev/null \
      | tr -d '\r' \
      | awk 'tolower($1) == "x-amz-bucket-region:" { print $2 }' \
      | tail -n 1
  )"

  if [[ "$region" =~ ^[a-z0-9-]+$ ]]; then
    printf '%s\n' "$region"
  else
    log WARN "Unable to detect the region of bucket '$1'; using us-east-1 (set AWS_REGION to override)"
    printf 'us-east-1\n'
  fi
}

# Prepares the curl configuration for the given bucket. Credentials are only
# written to a private config file, never passed on the command line.
s3_init() {
  local bucket="$1"
  local access_key="${AWS_ACCESS_KEY_ID:-}"
  local secret_key="${AWS_SECRET_ACCESS_KEY:-}"
  local session_token="${AWS_SESSION_TOKEN:-}"
  local endpoint="${AWS_ENDPOINT_URL:-}"
  local style="${S3_ADDRESSING_STYLE:-auto}"

  require_command curl
  [[ -n "$access_key" ]] || die "AWS_ACCESS_KEY_ID environment variable is not set"
  [[ -n "$secret_key" ]] || die "AWS_SECRET_ACCESS_KEY environment variable is not set"
  s3_validate_bucket "$bucket"
  s3_parse_part_size

  s3_allow_unconditional=0
  if [[ "${S3_ALLOW_UNCONDITIONAL_WRITES:-0}" == 1 ]]; then
    s3_allow_unconditional=1
  fi

  s3_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

  if [[ -z "$endpoint" ]]; then
    [[ -n "$s3_region" ]] || s3_region="$(s3__detect_aws_region "$bucket")"
    endpoint="https://s3.${s3_region}.amazonaws.com"
    if [[ "$style" == auto ]]; then
      # Dotted bucket names do not match the *.s3 TLS certificate.
      if [[ "$bucket" == *.* ]]; then style=path; else style=virtual; fi
    fi
  else
    [[ -n "$s3_region" ]] || s3_region="us-east-1"
    [[ "$style" != auto ]] || style=path
  fi

  [[ "$s3_region" =~ ^[a-z0-9-]+$ ]] || die "Invalid S3 region: '$s3_region'"

  [[ "$endpoint" =~ ^(https?)://([A-Za-z0-9.-]+(:[0-9]+)?)/?$ ]] || die \
    "Invalid AWS_ENDPOINT_URL: '$endpoint'. Expected scheme://host[:port]"
  s3_scheme="${BASH_REMATCH[1]}"
  s3_host="${BASH_REMATCH[2]}"

  case "$style" in
    path | virtual) s3_style="$style" ;;
    *) die "Invalid S3_ADDRESSING_STYLE: '$style'. Expected auto, path or virtual" ;;
  esac

  ensure_work_dir
  s3_curl_config="${work_dir}/curl-s3.conf"
  (
    umask 077
    {
      printf 'silent\nshow-error\nconnect-timeout = 30\n'
      printf 'user = %s\n' "$(s3__config_quote "${access_key}:${secret_key}")"
      printf 'aws-sigv4 = %s\n' "$(s3__config_quote "aws:amz:${s3_region}:s3")"
      if [[ -n "$session_token" ]]; then
        printf 'header = %s\n' "$(s3__config_quote "x-amz-security-token: ${session_token}")"
      fi
    } > "$s3_curl_config"
  )
}

s3_url_for() {
  local bucket="$1" key="${2:-}"
  if [[ "$s3_style" == virtual ]]; then
    printf '%s://%s.%s/%s' "$s3_scheme" "$bucket" "$s3_host" "$key"
  else
    printf '%s://%s/%s/%s' "$s3_scheme" "$s3_host" "$bucket" "$key"
  fi
}

s3__bucket_url() {
  if [[ "$s3_style" == virtual ]]; then
    printf '%s://%s.%s/' "$s3_scheme" "$1" "$s3_host"
  else
    printf '%s://%s/%s' "$s3_scheme" "$s3_host" "$1"
  fi
}

# ------------------------------------------------------------------------------
# Low-level request helpers
# ------------------------------------------------------------------------------

# Usage: s3__call <body-file> <headers-file> <curl args...>
# Sets S3_STATUS (HTTP status, 000 on transport failure) and S3_CURL_RC; the
# error message of curl is kept for s3__describe. An HTTP status with a
# non-zero curl exit (for example a body that broke off, exit 18) is not a
# complete answer: callers must check S3_CURL_RC as well.
s3__call() {
  local body="$1" headers="$2"
  shift 2

  S3_CURL_RC=0
  S3_STATUS="$(curl -K "$s3_curl_config" -o "$body" -D "$headers" -w '%{http_code}' "$@" 2> "${work_dir}/curl.err")" \
    || S3_CURL_RC=$?
  [[ -n "$S3_STATUS" ]] || S3_STATUS=000
}

# Prints the first line of the last curl error message, if any.
s3__curl_error() {
  head -n 1 -- "${work_dir}/${1:-curl.err}" 2>/dev/null || true
}

s3__error_code() {
  [[ -f "$1" ]] || return 0
  sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p' "$1" | head -n 1
}

s3__describe() {
  local code
  code="$(s3__error_code "$1")"
  printf 'HTTP %s%s' "$S3_STATUS" "${code:+ ($code)}"
  if (( S3_CURL_RC != 0 )); then
    local error
    error="$(s3__curl_error)"
    printf ', curl exit %s%s' "$S3_CURL_RC" "${error:+: $error}"
  fi
}

# Prints the value of the last occurrence of a response header.
s3__header() {
  tr -d '\r' < "$1" | awk -v name="$2" '
    {
      sep = index($0, ":")
      if (sep > 0 && tolower(substr($0, 1, sep - 1)) == tolower(name)) {
        value = substr($0, sep + 1)
        sub(/^[ \t]+/, "", value)
        found = value
      }
    }
    END { if (found != "") print found }
  '
}

# ------------------------------------------------------------------------------
# Objects
# ------------------------------------------------------------------------------

# Returns 0 if the object exists and 1 if it does not. Any other answer is
# fatal: an ambiguous result must never be treated as "missing".
s3_head() {
  local bucket="$1" key="$2"
  ensure_work_dir
  s3_head_headers="${work_dir}/head.headers"

  s3__call /dev/null "$s3_head_headers" --retry 3 --head "$(s3_url_for "$bucket" "$key")"
  (( S3_CURL_RC == 0 )) || die "Failed to check s3://${bucket}/${key}: $(s3__describe /dev/null)"

  case "$S3_STATUS" in
    200) return 0 ;;
    404) return 1 ;;
    403)
      die "Access denied while checking s3://${bucket}/${key} (HTTP 403). The credentials need s3:GetObject and s3:ListBucket; without ListBucket S3 answers 403 instead of 404 for missing keys"
      ;;
    *) die "Failed to check s3://${bucket}/${key}: $(s3__describe /dev/null)" ;;
  esac
}

s3__object_has_token() {
  local bucket="$1" key="$2" token="$3"
  s3_head "$bucket" "$key" || return 1
  [[ "$(s3__header "$s3_head_headers" x-amz-meta-vb-token)" == "$token" ]]
}

# Streams an object to stdout. HTTP errors make curl exit non-zero, which
# fails the surrounding pipeline. There is no retry: a stream cannot be rewound.
s3_get() {
  curl -K "$s3_curl_config" --fail -o - "$(s3_url_for "$1" "$2")"
}

# Downloads a small object to a file. Returns 1 if it does not exist.
s3_get_file() {
  local bucket="$1" key="$2" out="$3"
  s3__call "$out" "${work_dir}/get.headers" --retry 3 "$(s3_url_for "$bucket" "$key")"
  (( S3_CURL_RC == 0 )) || die "Failed to download s3://${bucket}/${key}: $(s3__describe "$out")"

  case "$S3_STATUS" in
    200) return 0 ;;
    404) return 1 ;;
    *) die "Failed to download s3://${bucket}/${key}: $(s3__describe "$out")" ;;
  esac
}

s3__require_unconditional_optin() {
  (( s3_allow_unconditional )) || return 1
  log WARN "The S3 provider does not support conditional writes (If-None-Match); publishing without overwrite protection because S3_ALLOW_UNCONDITIONAL_WRITES=1"
}

readonly S3_NO_CONDITIONAL_WRITES_MSG="The S3 provider does not support conditional writes (If-None-Match: *), so a concurrent backup could silently overwrite this recovery point. Set S3_ALLOW_UNCONDITIONAL_WRITES=1 to accept that risk"

# Publishes a small file without ever overwriting an existing object.
# Returns 0 when published (or when an earlier attempt of ours already
# published it) and 3 when another object occupies the key.
s3_put_file() {
  local bucket="$1" key="$2" file="$3" token="$4"
  local url body headers attempt uncertain=0
  local -a cond=(-H 'If-None-Match: *')

  url="$(s3_url_for "$bucket" "$key")"
  body="${work_dir}/put.body"
  headers="${work_dir}/put.headers"

  for attempt in 1 2 3; do
    s3__call "$body" "$headers" --upload-file "$file" -H "x-amz-meta-vb-token: ${token}" "${cond[@]}" "$url"
    # An answer that broke off is a lost answer: retry and check the token
    (( S3_CURL_RC == 0 )) || S3_STATUS=000

    case "$S3_STATUS" in
      200) return 0 ;;
      409 | 412)
        if (( uncertain )) && s3__object_has_token "$bucket" "$key" "$token"; then
          return 0
        fi
        return 3
        ;;
      501)
        s3__require_unconditional_optin || die "$S3_NO_CONDITIONAL_WRITES_MSG"
        if s3_head "$bucket" "$key"; then
          return 3
        fi
        cond=()
        ;;
      000 | 5??)
        uncertain=1
        sleep "$attempt"
        ;;
      *) die "Failed to upload s3://${bucket}/${key}: $(s3__describe "$body")" ;;
    esac
  done

  die "Failed to upload s3://${bucket}/${key} after retries: $(s3__describe "$body")"
}

# Deletes an object only if it still has the given ETag.
# Returns 0 when deleted (or already gone), 3 when the object changed and
# 4 when the provider does not support conditional deletes.
s3_delete_if_match() {
  local bucket="$1" key="$2" etag="$3"
  local body="${work_dir}/delete.body"
  local -a cond=()
  [[ -z "$etag" ]] || cond=(-H "If-Match: ${etag}")

  local attempt
  for attempt in 1 2 3; do
    s3__call "$body" "${work_dir}/delete.headers" --retry 3 -X DELETE "${cond[@]}" "$(s3_url_for "$bucket" "$key")"
    # An answer that broke off is a lost answer: ask again (a repeated
    # DELETE of a deleted object answers 404)
    (( S3_CURL_RC == 0 )) || S3_STATUS=000

    case "$S3_STATUS" in
      200 | 204 | 404) return 0 ;;
      412) return 3 ;;
      501) return 4 ;;
      000 | 5??) sleep "$attempt" ;;
      *) die "Failed to delete s3://${bucket}/${key}: $(s3__describe "$body")" ;;
    esac
  done
  die "Failed to delete s3://${bucket}/${key} after retries: $(s3__describe "$body")"
}

# Decodes XML character references, both named (&quot;) and numeric (&#34;,
# &#x22;): providers differ in which form they use.
# Checks with a probe object below <prefix> that the provider honours
# If-Match on DELETE. Returns 1 if it does not (the probe is removed anyway).
s3_probe_conditional_delete() {
  local bucket="$1" prefix="$2" key file etag rc=0

  key="${prefix:+${prefix}/}.vb-probe-$(random_hex 8)"
  file="${work_dir}/probe"
  printf 'vb conditional delete probe\n' > "$file"
  s3_put_file "$bucket" "$key" "$file" probe || die "Failed to write the probe object s3://${bucket}/${key}"
  s3_head "$bucket" "$key" || die "The probe object s3://${bucket}/${key} disappeared"
  etag="$(s3__header "$s3_head_headers" etag)"

  s3_delete_if_match "$bucket" "$key" '"00000000000000000000000000000000"' || rc=$?
  case "$rc" in
    3)
      rc=0
      s3_delete_if_match "$bucket" "$key" "$etag" || rc=$?
      (( rc == 0 )) || die "Failed to delete the probe object s3://${bucket}/${key}"
      return 0
      ;;
    0)
      # Deleted although the ETag did not match
      return 1
      ;;
    *)
      s3_delete_if_match "$bucket" "$key" "" || true
      return 1
      ;;
  esac
}

s3__xml_unescape() {
  awk '
    {
      out = ""
      while (match($0, /&(#[0-9]+|#[xX][0-9A-Fa-f]+|quot|apos|lt|gt|amp);/)) {
        entity = substr($0, RSTART + 1, RLENGTH - 2)
        if (entity == "quot") char = "\""
        else if (entity == "apos") char = "\047"
        else if (entity == "lt") char = "<"
        else if (entity == "gt") char = ">"
        else if (entity == "amp") char = "&"
        else if (substr(entity, 2, 1) == "x" || substr(entity, 2, 1) == "X") {
          hex = tolower(substr(entity, 3))
          code = 0
          for (i = 1; i <= length(hex); i++) code = code * 16 + index("0123456789abcdef", substr(hex, i, 1)) - 1
          char = sprintf("%c", code)
        } else {
          char = sprintf("%c", substr(entity, 2) + 0)
        }
        out = out substr($0, 1, RSTART - 1) char
        $0 = substr($0, RSTART + RLENGTH)
      }
      print out $0
    }
  '
}

# Returns 0 if the response <file> contains <text> and 1 if it does not. A
# read error is fatal: it must never pass for "not found".
s3__body_contains() {
  local rc=0
  grep -qF -- "$2" "$1" || rc=$?
  (( rc <= 1 )) || die "Failed to read the S3 response $1 (grep exit ${rc})"
  return "$rc"
}

# Lists the direct children of a prefix as "<key>\t<size>\t<etag>" lines.
# Meant for vb_collect: any failure, including a malformed entry, is fatal,
# so a listing is either complete or not used at all.
s3_list() {
  local bucket="$1" prefix="$2"
  local base body headers query token=""

  base="$(s3__bucket_url "$bucket")"
  body="${work_dir}/list.body"
  headers="${work_dir}/list.headers"
  [[ -z "$prefix" ]] || prefix="${prefix}/"

  while :; do
    query="delimiter=%2F&list-type=2&prefix=$(s3__urlencode "$prefix")"
    if [[ -n "$token" ]]; then
      query+="&continuation-token=$(s3__urlencode "$token")"
    fi

    s3__call "$body" "$headers" --retry 3 "${base}?${query}"
    [[ "$S3_STATUS" == 200 && "$S3_CURL_RC" == 0 ]] || die \
      "Failed to list s3://${bucket}/${prefix}: $(s3__describe "$body")"
    s3__body_contains "$body" '</ListBucketResult>' || die \
      "Incomplete listing of s3://${bucket}/${prefix}: the response ended early"

    # Every entry needs a key and a size
    tr '<' '\n' < "$body" | awk -F'>' '
      $1 == "Contents" { key = ""; size = ""; etag = ""; inside = 1 }
      inside && $1 == "Key" { key = $2 }
      inside && $1 == "Size" { size = $2 }
      inside && $1 == "ETag" { etag = $2 }
      $1 == "/Contents" {
        if (key == "" || size !~ /^[0-9]+$/) { bad = 1; exit }
        print key "\t" size "\t" etag
        inside = 0
      }
      END { if (bad) exit 3 }
    ' | s3__xml_unescape || die "Failed to parse the listing of s3://${bucket}/${prefix}"

    s3__body_contains "$body" '<IsTruncated>true</IsTruncated>' || break

    token="$(sed -n 's:.*<NextContinuationToken>\([^<]*\)</NextContinuationToken>.*:\1:p' "$body")" \
      || die "Failed to read the continuation token of s3://${bucket}/${prefix}"
    token="$(printf '%s\n' "${token%%$'\n'*}" | s3__xml_unescape)" \
      || die "Failed to decode the continuation token of s3://${bucket}/${prefix}"
    [[ -n "$token" ]] || die "S3 listing of s3://${bucket}/${prefix} is truncated but has no continuation token"
  done
}

# ------------------------------------------------------------------------------
# Multipart upload
# ------------------------------------------------------------------------------

s3_mp_begin() {
  local body headers
  s3_mp_bucket="$1"
  s3_mp_key="$2"
  s3_mp_token="$3"
  s3_mp_url="$(s3_url_for "$s3_mp_bucket" "$s3_mp_key")"
  s3_mp_parts_file="${work_dir}/mp.parts"
  body="${work_dir}/mp.body"
  headers="${work_dir}/mp.headers"
  : > "$s3_mp_parts_file"

  s3__call "$body" "$headers" -X POST -H "x-amz-meta-vb-token: ${s3_mp_token}" "${s3_mp_url}?uploads"
  [[ "$S3_STATUS" == 200 && "$S3_CURL_RC" == 0 ]] || die \
    "Failed to start multipart upload to s3://${s3_mp_bucket}/${s3_mp_key}: $(s3__describe "$body")"

  s3_mp_upload_id="$(sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p' "$body" | head -n 1)"
  [[ -n "$s3_mp_upload_id" ]] || die "S3 did not return an upload id for s3://${s3_mp_bucket}/${s3_mp_key}"
  s3_mp_upload_id_enc="$(s3__urlencode "$s3_mp_upload_id")"
}

# Reads the stream from stdin and uploads it in parts of S3_PART_SIZE. Meant
# to be the last element of a pipeline; it reports failures by its exit status.
s3_mp_upload_parts() {
  local part="${work_dir}/mp.part"
  local part_bytes=$(( s3_part_mb * 1048576 ))
  local number=0 size etag

  while :; do
    if ! dd bs=1M count="$s3_part_mb" iflag=fullblock of="$part" status=none; then
      log ERROR "Failed to buffer the backup stream for upload"
      return 1
    fi

    size="$(stat -c %s "$part")"
    if (( size == 0 && number > 0 )); then
      break
    fi

    number=$((number + 1))
    if (( number > 10000 )); then
      log ERROR "The backup exceeds 10000 parts of ${s3_part_mb} MiB; increase S3_PART_SIZE"
      return 1
    fi

    vb_test_point "s3_part_${number}"

    if ! etag="$(curl -K "$s3_curl_config" --fail --retry 3 --upload-file "$part" -o /dev/null \
      -w '%header{etag}' "${s3_mp_url}?partNumber=${number}&uploadId=${s3_mp_upload_id_enc}" \
      2> "${work_dir}/curl.part.err")" || [[ -z "$etag" ]]; then
      local error
      error="$(s3__curl_error curl.part.err)"
      log ERROR "Failed to upload part ${number} of s3://${s3_mp_bucket}/${s3_mp_key}${error:+: $error}"
      return 1
    fi

    printf '%s %s\n' "$number" "$etag" >> "$s3_mp_parts_file"

    if (( size < part_bytes )); then
      break
    fi
  done

  rm -f "$part"
}

s3_mp_abort() {
  [[ -n "$s3_mp_upload_id" ]] || return 0

  if ! curl -K "$s3_curl_config" --fail --retry 2 -o /dev/null -X DELETE \
    "${s3_mp_url}?uploadId=${s3_mp_upload_id_enc}" > /dev/null 2> "${work_dir}/curl.abort.err"; then
    local error
    error="$(s3__curl_error curl.abort.err)"
    log WARN "Failed to abort the multipart upload to s3://${s3_mp_bucket}/${s3_mp_key}${error:+ ($error)}; an AbortIncompleteMultipartUpload lifecycle rule will clean it up"
  fi
  s3_mp_upload_id=""
}

# Completes the multipart upload without overwriting an existing object.
# Returns 0 when published and 3 when another object occupies the key (the
# upload is aborted). When a response gets lost and the retry reports a
# conflict, the object's token decides whether the earlier attempt was ours.
s3_mp_complete() {
  local xml="${work_dir}/mp.complete.xml"
  local body="${work_dir}/mp.body"
  local headers="${work_dir}/mp.headers"
  local attempt uncertain=0 code number etag
  local -a cond=(-H 'If-None-Match: *')

  {
    printf '<CompleteMultipartUpload>'
    while read -r number etag; do
      printf '<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>' "$number" "$etag"
    done < "$s3_mp_parts_file"
    printf '</CompleteMultipartUpload>'
  } > "$xml"

  for attempt in 1 2 3; do
    s3__call "$body" "$headers" -X POST -H 'Content-Type: application/xml' "${cond[@]}" \
      --data-binary "@${xml}" "${s3_mp_url}?uploadId=${s3_mp_upload_id_enc}"
    # An answer that broke off is a lost answer: retry and check the token
    (( S3_CURL_RC == 0 )) || S3_STATUS=000
    code="$(s3__error_code "$body")"

    if [[ "$S3_STATUS" == 200 && -z "$code" ]] && grep -q '<CompleteMultipartUploadResult' "$body"; then
      s3_mp_upload_id=""
      return 0
    fi

    case "${S3_STATUS}:${code}" in
      409:* | 412:* | 200:PreconditionFailed | 200:ConditionalRequestConflict)
        if (( uncertain )) && s3__object_has_token "$s3_mp_bucket" "$s3_mp_key" "$s3_mp_token"; then
          s3_mp_upload_id=""
          return 0
        fi
        s3_mp_abort
        return 3
        ;;
      404:*)
        if (( uncertain )) && s3__object_has_token "$s3_mp_bucket" "$s3_mp_key" "$s3_mp_token"; then
          s3_mp_upload_id=""
          return 0
        fi
        s3_mp_upload_id=""
        die "The multipart upload to s3://${s3_mp_bucket}/${s3_mp_key} disappeared before completion: $(s3__describe "$body")"
        ;;
      501:*)
        if ! s3__require_unconditional_optin; then
          s3_mp_abort
          die "$S3_NO_CONDITIONAL_WRITES_MSG"
        fi
        if s3_head "$s3_mp_bucket" "$s3_mp_key"; then
          s3_mp_abort
          return 3
        fi
        cond=()
        ;;
      000:* | 5??:* | 200:InternalError | 200:SlowDown | 200:ServiceUnavailable)
        uncertain=1
        sleep "$attempt"
        ;;
      *)
        s3_mp_abort
        die "Failed to complete the multipart upload to s3://${s3_mp_bucket}/${s3_mp_key}: $(s3__describe "$body")"
        ;;
    esac
  done

  s3_mp_abort
  die "Failed to complete the multipart upload to s3://${s3_mp_bucket}/${s3_mp_key} after retries: $(s3__describe "$body")"
}

# Aborts an unfinished multipart upload; call from the EXIT trap.
s3_cleanup() {
  if [[ -n "$s3_mp_upload_id" && -n "$s3_curl_config" && -f "$s3_curl_config" ]]; then
    s3_mp_abort
  fi
}
