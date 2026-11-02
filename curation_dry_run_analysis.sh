#!/usr/bin/env bash
# Re-exec under Bash if launched from zsh.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -uo pipefail

# --------------------------------------------------
# 1. Pull Curation audit records that a dry-run policy would have blocked
# 2. Query the Catalog GraphQL API for publish date + fixed CVEs per package
# 3. Decide which ones would be bypassed (age >= MIN_AGE_DAYS, or fixes CVSS >= threshold)
# --------------------------------------------------

: "${JF_URL:?Please set JF_URL, e.g. https://your-instance.jfrog.io}"
: "${JF_TOKEN:?Please set JF_TOKEN to your JFrog access token}"

JF_URL="${JF_URL%/}"
AUDIT_URL="${JF_URL}/xray/api/v1/curation/audit/packages"
CATALOG_URL="${CATALOG_URL:-${JF_URL}/catalog/api/v1/public/graphql}"

MIN_AGE_DAYS="${MIN_AGE_DAYS:-7}"
CVSS_THRESHOLD="${CVSS_THRESHOLD:-7.0}"
PAGE_SIZE="${PAGE_SIZE:-1000}"

PACKAGES_CSV="dry_run_packages.csv"
VULNS_CSV="dry_run_vulnerabilities.csv"
REPORT_CSV="dry_run_bypass_report.csv"

POLICY_FILTER=""
MODE="dry-run"
FROM=""
TO=""
EXTRA_PARAMS=()
AUDIT_ACTION="${AUDIT_ACTION:-blocker}"

usage() {
  cat <<EOF
Usage: $0 [--policy NAME] [--mode dry-run|blocked|all] [--from DATE] [--to DATE]

  --policy NAME   Only include packages this policy blocked / would have blocked
  --mode MODE     dry-run: policies in dry-run mode that would block (default)
                  blocked: enforced policies that actually blocked
                  all:     both
  --from DATE     created_at_start (YYYY-MM-DD or RFC3339)
  --to DATE       created_at_end (YYYY-MM-DD or RFC3339)
  --param K=V     extra audit API query param (repeatable)

Env: JF_URL, JF_TOKEN (required); CATALOG_URL, MIN_AGE_DAYS (7), CVSS_THRESHOLD (7.0), PAGE_SIZE (1000),
     AUDIT_ACTION (blocker; sent as action= with dry_run=true in dry-run mode)

Outputs:
  $PACKAGES_CSV        type,name,version of dry-run packages
  $VULNS_CSV   compatible with analyze_policy_bypass.sh
  $REPORT_CSV     per-package bypass verdict
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--policy) POLICY_FILTER="${2:?--policy needs a value}"; shift 2 ;;
    -m|--mode)   MODE="${2:?--mode needs a value}"; shift 2 ;;
    --from)      FROM="${2:?--from needs a value}"; shift 2 ;;
    --to)        TO="${2:?--to needs a value}"; shift 2 ;;
    --param)     EXTRA_PARAMS+=(--data-urlencode "${2:?--param needs K=V}"); shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done

case "$MODE" in
  dry-run|blocked|all) ;;
  *) echo "ERROR: --mode must be dry-run, blocked or all" >&2; exit 1 ;;
esac

# Audit API requires RFC3339 timestamps.
[[ "$FROM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && FROM="${FROM}T00:00:00Z"
[[ "$TO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && TO="${TO}T23:59:59Z"

AUDIT_JSONL="$(mktemp)"
PACKAGES_JSON="$(mktemp)"
RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$AUDIT_JSONL" "$PACKAGES_JSON" "$RESULTS_JSONL"' EXIT

# --------------------------------------------------
# Step 1: Fetch Curation audit records (paginated)
# --------------------------------------------------
fetch_window() {
  local start="$1" end="$2" offset=0 count total resp
  local params
  while :; do
    params=(
      --data-urlencode "num_of_rows=${PAGE_SIZE}"
      --data-urlencode "offset=${offset}"
    )
    if [[ "$MODE" == "dry-run" ]]; then
      params+=(--data-urlencode "action=${AUDIT_ACTION}" --data-urlencode "dry_run=true")
    elif [[ "$MODE" == "blocked" ]]; then
      params+=(--data-urlencode "action=blocked")
    fi
    [[ -n "$start" ]] && params+=(--data-urlencode "created_at_start=${start}")
    [[ -n "$end" ]] && params+=(--data-urlencode "created_at_end=${end}")
    [[ ${#EXTRA_PARAMS[@]} -gt 0 ]] && params+=("${EXTRA_PARAMS[@]}")

    if ! resp="$(curl -sS --fail-with-body -G "$AUDIT_URL" \
        -H "Authorization: Bearer ${JF_TOKEN}" \
        -H "Accept: application/json" \
        "${params[@]}")"; then
      echo "ERROR: Audit API request failed: $resp" >&2
      exit 1
    fi

    count="$(jq '(.data // []) | length' <<< "$resp")"
    jq -c '.data[]?' <<< "$resp" >> "$AUDIT_JSONL"
    total="$(jq -r '.meta.total_count // empty' <<< "$resp")"

    offset=$((offset + count))
    echo "  ${start:-all} -> ${end:-now}: fetched ${offset}${total:+ / $total}" >&2

    (( count < PAGE_SIZE )) && break
    [[ -n "$total" && "$offset" -ge "$total" ]] && break
  done
}

to_epoch() { jq -rn --arg d "$1" '$d | fromdateiso8601'; }
to_iso()   { jq -rn --argjson e "$1" '$e | todateiso8601'; }

echo "Fetching Curation audit records..." >&2
if [[ -z "$FROM" && -z "$TO" ]]; then
  fetch_window "" ""
else
  # API rejects ranges longer than 168h, so walk the range in 7-day windows.
  WINDOW=604799
  end_epoch="$(if [[ -n "$TO" ]]; then to_epoch "$TO"; else date -u +%s; fi)" || exit 1
  start_epoch="$(if [[ -n "$FROM" ]]; then to_epoch "$FROM"; else echo $((end_epoch - WINDOW)); fi)" || exit 1
  while (( start_epoch <= end_epoch )); do
    win_end=$((start_epoch + WINDOW))
    (( win_end > end_epoch )) && win_end=$end_epoch
    fetch_window "$(to_iso "$start_epoch")" "$(to_iso "$win_end")"
    start_epoch=$((win_end + 1))
  done
fi

# Keep packages a policy blocked (or would have, in dry-run), deduped by type/name/version.
jq -s --arg pol "$POLICY_FILTER" --arg mode "$MODE" '
  def norm: tostring | ascii_downcase | gsub("[^a-z]"; "");
  map(
    (.action // "" | norm) as $action
    | . + {hits: [
        (.policies // [])[] | objects
        | select($pol == "" or .policy_name == $pol)
        | select((.result // "" | norm) as $r | ($r != "bypassed" and $r != "approved" and $r != "passed" and $r != "waived"))
        | . + {source: (if .dry_run == true or ($action | contains("dryrun")) then "dry_run" else "blocked" end)}
        | select($mode == "all" or ($mode == "dry-run" and .source == "dry_run") or ($mode == "blocked" and .source == "blocked"))
      ]}
  )
  | map(select(.hits | length > 0))
  | map({
      type:       ((.package_type // "") | ascii_downcase),
      name:       (.package_name // ""),
      version:    (.package_version // ""),
      created_at: (.created_at // ""),
      policies:   [.hits[].policy_name // empty],
      conditions: [.hits[].condition_name // empty],
      sources:    [.hits[].source],
      results:    [.hits[].result // empty | tostring]
    })
  | map(select(.type != "" and .name != "" and .version != ""))
  | group_by([.type, .name, .version])
  | map({
      type: .[0].type,
      name: .[0].name,
      version: .[0].version,
      first_seen: ([.[].created_at | select(. != "")] | min // ""),
      requests: length,
      source: ([.[].sources[]] | unique | join(";")),
      policies: ([.[].policies[]] | unique | join(";")),
      conditions: ([.[].conditions[]] | unique | join(";")),
      results: ([.[].results[]] | unique | join(";"))
    })
' "$AUDIT_JSONL" > "$PACKAGES_JSON"

pkg_count="$(jq 'length' "$PACKAGES_JSON")"
echo "Packages found (mode=${MODE}): ${pkg_count}" >&2

{
  echo '"package_type","package_name","package_version","source","first_seen","requests","policies","conditions","results"'
  jq -r '.[] | [.type, .name, .version, .source, .first_seen, .requests, .policies, .conditions, .results] | @csv' "$PACKAGES_JSON"
} > "$PACKAGES_CSV"

if [[ "$pkg_count" -eq 0 ]]; then
  echo "Nothing matched. Audit record shape for troubleshooting:" >&2
  jq -s --arg pol "$POLICY_FILTER" '{
    policy_dry_run_result_counts: (
      [.[] | (.policies // [])[] | objects | "\(.policy_name) | dry_run=\(.dry_run) | result=\(.result)"]
      | group_by(.) | map({(.[0]): length}) | add
    ),
    action_values: (map(.action | tostring) | group_by(.) | map({(.[0]): length}) | add),
    record_keys: (map(keys) | add | unique),
    sample_policies: (map(.policies) | map(select(. != null and . != [])) | .[0:3]),
    records_mentioning_policy: (if $pol == "" then null else map(select(tostring | contains($pol))) | length end),
    sample_record_for_policy: (if $pol == "" then null else (map(select(tostring | contains($pol))) | .[0]) end)
  }' "$AUDIT_JSONL" >&2
  exit 0
fi

# --------------------------------------------------
# Step 2: Catalog lookup per package
# --------------------------------------------------
now="$(date +%s)"
i=0
while IFS= read -r pkg; do
  i=$((i + 1))
  type="$(jq -r '.type' <<< "$pkg")"
  name="$(jq -r '.name' <<< "$pkg")"
  version="$(jq -r '.version' <<< "$pkg")"
  echo "[${i}/${pkg_count}] ${type}:${name}@${version}" >&2

  # jq-encode values so names/versions are safe GraphQL string literals.
  gql_type="$(jq -n --arg v "$type" '$v')"
  gql_name="$(jq -n --arg v "$name" '$v')"
  gql_version="$(jq -n --arg v "$version" '$v')"

  query=$(cat <<EOF
query {
  publicPackages {
    searchPackageVersions(
      first: 1
      where: { publicPackageVersionIn: [{ type: ${gql_type}, name: ${gql_name}, version: ${gql_version} }] }
    ) {
      edges {
        packageVersion: node {
          version
          publishedAt
          securityInfo {
            fixedVulnerabilitiesConnection(
              where: { hasCvssWith: [{ preferredBaseScoreGTE: 0 }] }
              orderBy: { direction: DESC, field: CVSS_PREFERRED_BASE_SCORE }
              first: 100
            ) {
              edges { node { name cvss { preferredBaseScore } } }
            }
          }
        }
      }
    }
  }
}
EOF
)

  if ! resp="$(curl -sS --fail-with-body -X POST "$CATALOG_URL" \
      -H "Authorization: Bearer ${JF_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg q "$query" '{query: $q}')")"; then
    echo "  WARNING: Catalog request failed: $resp" >&2
    resp='{}'
  fi

  if jq -e '(.errors // []) | length > 0' >/dev/null 2>&1 <<< "$resp"; then
    echo "  WARNING: GraphQL error: $(jq -c '.errors' <<< "$resp")" >&2
  fi

  jq -c \
    --argjson pkg "$pkg" \
    --argjson now "$now" \
    --argjson min_age "$MIN_AGE_DAYS" \
    --argjson threshold "$CVSS_THRESHOLD" '
    def epoch: (.[:19] + "Z") | fromdateiso8601;
    (.data.publicPackages.searchPackageVersions.edges[0]?.packageVersion // null) as $pv
    | ($pv.publishedAt // "") as $pub
    | (if $pub != "" then (try ($pub | epoch) catch null) else null end) as $pubEpoch
    | (if $pkg.first_seen != "" then (try ($pkg.first_seen | epoch) catch $now) else $now end) as $reqEpoch
    | [($pv.securityInfo.fixedVulnerabilitiesConnection.edges // [])[].node
        | {name: (.name // ""), score: (.cvss.preferredBaseScore // 0)}] as $cves
    | [$cves[] | select(.score >= $threshold) | .name] as $high
    | (if $pubEpoch then (($reqEpoch - $pubEpoch) / 86400 | floor) else null end) as $ageAtReq
    | $pkg + {
        found: ($pv != null),
        published_at: $pub[:10],
        age_at_request_days: $ageAtReq,
        current_age_days: (if $pubEpoch then (($now - $pubEpoch) / 86400 | floor) else null end),
        cves: $cves,
        fixed_cve_count: ($cves | length),
        max_cvss: ([$cves[].score] | max // 0),
        high_cves: $high,
        verdict: (
          if $pv == null or $ageAtReq == null then "UNKNOWN_NOT_IN_CATALOG"
          elif $ageAtReq >= $min_age then "ALLOWED_AGE"
          elif ($high | length) > 0 then "BYPASS_CVSS_FIX"
          else "WAIVER_NEEDED" end
        )
      }
  ' <<< "$resp" >> "$RESULTS_JSONL"
done < <(jq -c '.[]' "$PACKAGES_JSON")

# --------------------------------------------------
# Step 3: Write outputs + bypass summary
# --------------------------------------------------
# Same 12-column layout as get-dependencies.sh so analyze_policy_bypass.sh can consume it.
{
  echo '"root_package_type","root_package_name","root_package_version","package_type","package_name","package_version","is_direct","path","fixed_cve_names","cvss_score","published_at","published_age_days"'
  jq -r '
    . as $p
    | (if ($p.cves | length) > 0 then $p.cves[] else {name: "NONE", score: 0} end)
    | [$p.type, $p.name, $p.version, $p.type, $p.name, $p.version, "true", "root",
       .name, (.score | tostring), $p.published_at, ($p.age_at_request_days // "" | tostring)]
    | @csv
  ' "$RESULTS_JSONL"
} > "$VULNS_CSV"

{
  echo '"package_type","package_name","package_version","source","policies","conditions","first_seen","requests","published_at","age_at_request_days","current_age_days","fixed_cve_count","max_fixed_cvss","high_cvss_fixed_cves","verdict"'
  jq -r '
    [.type, .name, .version, .source, .policies, .conditions, .first_seen, .requests, .published_at,
     (.age_at_request_days // "" | tostring), (.current_age_days // "" | tostring),
     .fixed_cve_count, .max_cvss, (.high_cves | join(";")), .verdict]
    | @csv
  ' "$RESULTS_JSONL"
} > "$REPORT_CSV"

echo
printf "%-10s %-45s %-20s %-16s %-8s %-8s %s\n" "TYPE" "PACKAGE" "VERSION" "SOURCE" "AGE(d)" "MAXCVSS" "VERDICT"
jq -r '[.type, .name, .version, .source, (.age_at_request_days // "-" | tostring), (.max_cvss | tostring), .verdict] | @tsv' "$RESULTS_JSONL" \
  | while IFS=$'\t' read -r t n v s a c verdict; do
      printf "%-10s %-45s %-20s %-16s %-8s %-8s %s\n" "$t" "$n" "$v" "$s" "$a" "$c" "$verdict"
    done

echo
jq -s --argjson min_age "$MIN_AGE_DAYS" --argjson threshold "$CVSS_THRESHOLD" '
  length as $total
  | (map(select(.verdict == "ALLOWED_AGE")) | length) as $age
  | (map(select(.verdict == "BYPASS_CVSS_FIX")) | length) as $bypass
  | (map(select(.verdict == "WAIVER_NEEDED")) | length) as $waiver
  | (map(select(.verdict == "UNKNOWN_NOT_IN_CATALOG")) | length) as $unknown
  | {
      rule: "allowed if age >= \($min_age)d, bypassed if younger but fixes CVSS >= \($threshold)",
      total_packages: $total,
      allowed_by_age: $age,
      bypassed_due_to_cvss_fix: $bypass,
      waivers_needed: $waiver,
      not_found_in_catalog: $unknown,
      bypass_and_allow_percentage: (if $total > 0 then ((($age + $bypass) / $total) * 10000 | floor) / 100 else 0 end)
    }
' "$RESULTS_JSONL"

echo
echo "Written: $PACKAGES_CSV, $VULNS_CSV, $REPORT_CSV" >&2
