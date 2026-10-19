#!/usr/bin/env bash

CSV_FILE="${1:-dependencies_vulnerabilities.csv}"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: Output CSV file '$CSV_FILE' not found." >&2
  exit 1
fi

jq -s -R '
  # Read CSV lines (skip header)
  split("\n")[1:] 
  | map(select(length > 0) | split(","))
  | map({
      root_pkg: .[1] | gsub("\""; ""),
      pkg_name: .[4] | gsub("\""; ""),
      pkg_ver:  .[5] | gsub("\""; ""),
      cve_name: .[8] | gsub("\""; ""),
      cvss:     (.[9]  | gsub("\""; "") | tonumber? // 0),
      age_days: (.[11] | gsub("\""; "") | tonumber? // 0)
    })
  # Group records by individual package version
  | group_by(.pkg_name + "@" + .pkg_ver)
  | map(
      .[0] as $base |
      {
        package: ($base.pkg_name + "@" + $base.pkg_ver),
        age_days: $base.age_days,
        has_high_cvss_fix: (map(select(.cvss >= 7.0 and .cve_name != "NONE")) | length > 0)
      }
    )
  | map(
      . + {
        # Bypass logic:
        # 1. Allowed if age >= 7 days
        # 2. Bypassed if age < 7 days BUT it fixes a CVSS >= 7.0 CVE
        # 3. Blocked ONLY if age < 7 days AND has no CVSS >= 7.0 fix
        is_allowed: (.age_days >= 7 or .has_high_cvss_fix)
      }
    ) as $evaluations
  | ($evaluations | length) as $total_count
  | ($evaluations | map(select(.is_allowed)) | length) as $allowed_count
  | ($evaluations | map(select(.is_allowed | not)) | length) as $blocked_count
  | ($evaluations | map(select(.age_days < 7 and .has_high_cvss_fix)) | length) as $cvss_bypassed_count
  | {
      total_packages_evaluated: $total_count,
      packages_allowed_without_waiver: $allowed_count,
      packages_bypassed_due_to_cvss7_plus: $cvss_bypassed_count,
      waivers_needed_to_be_raised: $blocked_count,
      bypass_and_allow_percentage: (
        if $total_count > 0 then
          ((($allowed_count / $total_count) * 10000 | floor) / 100)
        else 0 end
      )
    }
' "$CSV_FILE"
