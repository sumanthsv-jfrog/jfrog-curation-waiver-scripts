#!/bin/bash
#
# list-waivers.sh
#
# Lists JFrog Curation waiver requests (packages requested to be unblocked).
# Endpoint: GET {JFROG_URL}/xray/api/v1/curation/waiver_requests
#
# Usage:
#   ./list-waivers.sh <JFROG_URL> <JFROG_TOKEN> [options]
#
# Options:
#   --status <approved|rejected|pending|all>   Filter by status (default: pending)
#   --pkg-type <type>                      Filter by package type (npm, pypi, ...)
#   --pkg-name <name>                      Filter by package name
#   --pkg-version <version>                Filter by package version
#   --can-approve                          Only requests the current user can approve
#   --rows <n>                             Rows per page (default: 50)
#   --csv                                  Output name,version,type CSV (feeds the label scripts)
#
# Requires: curl, jq
#
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
list-waivers.sh — list JFrog Curation waiver requests

USAGE:
  ./list-waivers.sh <JFROG_URL> <JFROG_TOKEN> [options]

ARGUMENTS:
  JFROG_URL      JFrog platform base URL, e.g. https://myorg.jfrog.io
  JFROG_TOKEN    Access token (Bearer)

OPTIONS:
  --status <approved|rejected|pending|all>   Filter by status (default: pending; use all for every status)
  --pkg-type <type>                      Filter by package type (npm, pypi, ...)
  --pkg-name <name>                      Filter by package name
  --pkg-version <version>                Filter by package version
  --can-approve                          Only requests the current user can approve
  --rows <n>                             Rows per page (default: 50)
  --json                                 Output raw JSON instead of CSV
  --csv                                  Output CSV (this is the default)
  -h, --help                             Show this help and exit

OUTPUT (CSV, default):
  Columns: name,version,type,status,id,repo_key,created_at,closed_at,
           waiver_expiry,waiver_expiry_status,requesters
  Multiple requesters are de-duplicated and joined with ';'.
  The first three columns are name,version,type so you can feed the
  label scripts directly:   ... --status approved | tail -n +2 | cut -d, -f1-3

EXAMPLES:
  # Pending waivers (default)
  ./list-waivers.sh https://myorg.jfrog.io "$TOKEN"

  # Approved waivers as CSV
  ./list-waivers.sh https://myorg.jfrog.io "$TOKEN" --status approved

  # Every status (pending + approved + rejected)
  ./list-waivers.sh https://myorg.jfrog.io "$TOKEN" --status all

  # Feed approved waivers into the label scripts (name,version,type only)
  ./list-waivers.sh https://myorg.jfrog.io "$TOKEN" --status approved \
    | tail -n +2 | cut -d, -f1-3 | sort -u > waivers.csv

  # Raw JSON for inspection
  ./list-waivers.sh https://myorg.jfrog.io "$TOKEN" --json

REQUIRES: curl, jq
EOF
}

# Show help if requested (works in any position, before required-arg checks)
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

JFROG_URL="${1:?Enter JFrog URL e.g. https://myorg.jfrog.io (use -h for help)}"
JFROG_TOKEN="${2:?Enter JFrog Token (use -h for help)}"
shift 2

# ── Defaults ──────────────────────────────────────────────────────────────────

STATUS="pending"
PKG_TYPE=""
PKG_NAME=""
PKG_VERSION=""
CAN_APPROVE="false"
ROWS=50
OUTPUT="csv"          # csv (default) or json

# ── Parse options ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)       STATUS="$2"; shift 2 ;;
    --pkg-type)     PKG_TYPE="$2"; shift 2 ;;
    --pkg-name)     PKG_NAME="$2"; shift 2 ;;
    --pkg-version)  PKG_VERSION="$2"; shift 2 ;;
    --can-approve)  CAN_APPROVE="true"; shift ;;
    --rows)         ROWS="$2"; shift 2 ;;
    --json)         OUTPUT="json"; shift ;;
    --csv)          OUTPUT="csv"; shift ;;   # default; kept for back-compat
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1 (use -h for help)" >&2; exit 1 ;;
  esac
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required." >&2; exit 1; }
done

case "$STATUS" in
  pending|approved|rejected|all) ;;
  *) echo "Error: invalid --status '$STATUS' (use pending, approved, rejected, or all)" >&2; exit 1 ;;
esac

ENDPOINT="$JFROG_URL/xray/api/v1/curation/waiver_requests"

# ── Fetch a single page ───────────────────────────────────────────────────────
# Uses 1-based page_num (per API meta) rather than offset; offset was unreliable
# on some instances and could repeat page 1, truncating results.

fetch_page() {
  local page_num="$1"
  local status="$2"

  set -- -s -G "$ENDPOINT" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    --data-urlencode "status=$status" \
    --data-urlencode "num_of_rows=$ROWS" \
    --data-urlencode "page_num=$page_num" \
    --data-urlencode "order_by=updated_at" \
    --data-urlencode "direction=desc"

  [ "$CAN_APPROVE" = "true" ] && set -- "$@" --data-urlencode "can_approve=true"
  [ -n "$PKG_TYPE" ]    && set -- "$@" --data-urlencode "pkg_type=$PKG_TYPE"
  [ -n "$PKG_NAME" ]    && set -- "$@" --data-urlencode "pkg_name=$PKG_NAME"
  [ -n "$PKG_VERSION" ] && set -- "$@" --data-urlencode "pkg_version=$PKG_VERSION"

  curl "$@"
}

# ── Extract the array of rows regardless of wrapper key ───────────────────────

extract_rows() {
  jq -c 'if type=="array" then .
         elif .data then .data
         elif .waiver_requests then .waiver_requests
         elif .requests then .requests
         elif .rows then .rows
         else [] end'
}

# ── Emit rows from one API response ───────────────────────────────────────────

emit_rows() {
  local rows="$1"
  if [ "$OUTPUT" = "csv" ]; then
    # name,version,type first (so `cut -d, -f1-3` feeds the label scripts).
    # Multiple requesters are reduced to unique users joined by ';'.
    echo "$rows" | jq -r '.[]
      | [ (.pkg_name             // ""),
          (.pkg_version          // ""),
          (.pkg_type             // ""),
          (.status               // ""),
          (.id                   // "" | tostring),
          (.repo_key             // ""),
          (.created_at           // ""),
          (.closed_at            // ""),
          (.waiver_expiry        // ""),
          (.waiver_expiry_status // ""),
          ([.requesters[]?.user] | unique | join(";")) ]
      | join(",")'
  else
    echo "$rows" | jq '.'
  fi
}

# ── Paginate one status value ─────────────────────────────────────────────────

list_status() {
  local status="$1"
  local page_num=1
  local fetched=0
  local api_total=""
  local MAX_PAGES=1000

  while [ "$page_num" -le "$MAX_PAGES" ]; do
    local response
    response="$(fetch_page "$page_num" "$status")"

    # Surface HTTP/permission errors that come back as JSON
    if echo "$response" | jq -e '.errors // .error // empty' >/dev/null 2>&1; then
      echo "API error for status=$status page $page_num:" >&2
      echo "$response" | jq '.' >&2
      exit 1
    fi

    local rows count page_total
    rows="$(echo "$response" | extract_rows)"
    count="$(echo "$rows" | jq 'length')"

    # Empty page => we've gone past the last page; done.
    [ "$count" -eq 0 ] && break

    page_total="$(echo "$response" | jq -r '.meta.total_count // empty')"
    [ -n "$page_total" ] && api_total="$page_total"

    emit_rows "$rows"
    fetched=$((fetched + count))

    # Full page and more remain according to meta.total_count
    if [ -n "$api_total" ] && [ "$fetched" -ge "$api_total" ]; then
      break
    fi

    # Short page => last page when meta.total_count is absent
    [ "$count" -lt "$ROWS" ] && break

    page_num=$((page_num + 1))
  done

  if [ -n "$api_total" ] && [ "$fetched" -lt "$api_total" ]; then
    echo "Warning: status=$status returned $fetched of $api_total waiver request(s)." >&2
  fi

  TOTAL=$((TOTAL + fetched))
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [ "$OUTPUT" = "csv" ]; then
  echo "name,version,type,status,id,repo_key,created_at,closed_at,waiver_expiry,waiver_expiry_status,requesters"
fi

TOTAL=0
if [ "$STATUS" = "all" ]; then
  STATUSES=(pending approved rejected)
else
  STATUSES=("$STATUS")
fi

for status in "${STATUSES[@]}"; do
  list_status "$status"
done

echo "Listed $TOTAL waiver request(s) (status=$STATUS)." >&2
