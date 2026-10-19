#!/usr/bin/env bash

set -uo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------
: "${JF_URL:?Please set JF_URL, e.g. https://your-instance.jfrog.io}"
: "${JF_TOKEN:?Please set JF_TOKEN to your JFrog access token}"

INPUT_FILE="${1:-packages.csv}"
OUTPUT_FILE="${2:-dependencies_vulnerabilities.csv}"
PAGE_SIZE=100

# Remove trailing slash from URL
JF_URL="${JF_URL%/}"
API_URL="${JF_URL}/onemodel/api/v1/graphql"

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: Input file '$INPUT_FILE' not found." >&2
  exit 1
fi

# Write CSV output header
printf '"root_package_type","root_package_name","root_package_version","package_type","package_name","package_version","is_direct","path","fixed_cve_names","cvss_score","published_at","published_age_days"\n' > "$OUTPUT_FILE"

# Helper function to fetch security info for the root package itself
fetch_root_vulnerabilities() {
  local pkg_type="$1"
  local pkg_name="$2"
  local pkg_ver="$3"

  local gql_type gql_name gql_version
  gql_type="$(jq -Rn --arg v "$pkg_type" '$v')"
  gql_name="$(jq -Rn --arg v "$pkg_name" '$v')"
  gql_version="$(jq -Rn --arg v "$pkg_ver" '$v')"

  local query
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
              edges {
                node {
                  name
                  cvss {
                    preferredBaseScore
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
EOF
)

  local response
  response="$(curl -sS --fail-with-body \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JF_TOKEN" \
    --data "$(jq -cn --arg query "$query" '{query: $query}')" \
  )" || return 0

  jq -r \
    --arg rtype "$pkg_type" \
    --arg rpkg "$pkg_name" \
    --arg rver "$pkg_ver" \
    --argjson now "$(date +%s)" '
    .data.publicPackages.searchPackageVersions.edges[0]?.packageVersion as $pv
    | ($pv.publishedAt // "") as $pubRaw
    | (if $pubRaw != "" then ($pubRaw[:10]) else "" end) as $pubDate
    | (if $pubRaw != "" then
        try (
          (($pubRaw[:19] + "Z") | fromdateiso8601) as $pubEpoch
          | (($now - $pubEpoch) / 86400 | floor | tostring)
        ) catch ""
       else "" end) as $pubAgeDays
    | ($pv.securityInfo.fixedVulnerabilitiesConnection.edges // []) as $edges
    | if ($edges | length) > 0 then
        $edges[] | [
          $rtype, $rpkg, $rver,
          $rtype, $rpkg, $rver,
          "true", "root",
          (.node.name // "NONE"),
          ((.node.cvss.preferredBaseScore // 0) | tostring),
          $pubDate, $pubAgeDays
        ]
      else
        [
          $rtype, $rpkg, $rver,
          $rtype, $rpkg, $rver,
          "true", "root",
          "NONE", "0",
          $pubDate, $pubAgeDays
        ]
      end
    | @csv
  ' <<< "$response" >> "$OUTPUT_FILE"
}

# --------------------------------------------------
# Main Input CSV Processing
# --------------------------------------------------
while IFS=, read -r PACKAGE_TYPE PACKAGE VERSION || \
  [[ -n "${PACKAGE_TYPE:-}${PACKAGE:-}${VERSION:-}" ]]; do

  PACKAGE_TYPE="${PACKAGE_TYPE%$'\r'}"
  PACKAGE="${PACKAGE:-}"
  VERSION="${VERSION:-}"

  PACKAGE_TYPE="$(printf '%s' "$PACKAGE_TYPE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  PACKAGE="$(printf '%s' "$PACKAGE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  VERSION="$(printf '%s' "$VERSION" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  [[ -z "$PACKAGE_TYPE" ]] && continue
  [[ "$PACKAGE_TYPE" == \#* ]] && continue
  [[ "$(printf '%s' "$PACKAGE_TYPE" | tr '[:upper:]' '[:lower:]')" == "packagetype" ]] && continue

  if [[ -z "$PACKAGE" || -z "$VERSION" ]]; then
    echo "WARNING: Skipping invalid row: $PACKAGE_TYPE,$PACKAGE,$VERSION" >&2
    continue
  fi

  echo "Processing ${PACKAGE_TYPE}:${PACKAGE}@${VERSION}..."

  # 1. Fetch vulnerabilities for the root package
  fetch_root_vulnerabilities "$PACKAGE_TYPE" "$PACKAGE" "$VERSION"

  AFTER=""
  FOUND_PACKAGE=false

  # 2. Query dependencies with integrated vulnerability and publication details
  while :; do

    GQL_TYPE="$(jq -Rn --arg v "$PACKAGE_TYPE" '$v')"
    GQL_PACKAGE="$(jq -Rn --arg v "$PACKAGE" '$v')"
    GQL_VERSION="$(jq -Rn --arg v "$VERSION" '$v')"

    if [[ -n "$AFTER" ]]; then
      GQL_AFTER="$(jq -Rn --arg v "$AFTER" '$v')"
      AFTER_ARGUMENT=", after: ${GQL_AFTER}"
    else
      AFTER_ARGUMENT=""
    fi

    # Combined Query: Fetches dependency nodes and security information in 1 API call
    DEP_QUERY=$(cat <<EOF
query {
  publicPackages {
    getPackageVersion(
      type: ${GQL_TYPE}
      name: ${GQL_PACKAGE}
      version: ${GQL_VERSION}
    ) {
      version
      dependencies {
        dependenciesConnection(first: ${PAGE_SIZE}${AFTER_ARGUMENT}) {
          totalCount
          edges {
            node {
              isDirect
              path
              version {
                version
                publishedAt
                publicPackage {
                  name
                }
                securityInfo {
                  fixedVulnerabilitiesConnection(
                    where: { hasCvssWith: [{ preferredBaseScoreGTE: 0 }] }
                    orderBy: { direction: DESC, field: CVSS_PREFERRED_BASE_SCORE }
                    first: 100
                  ) {
                    edges {
                      node {
                        name
                        cvss {
                          preferredBaseScore
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
}
EOF
)

    RESPONSE="$(curl -sS --fail-with-body \
      -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $JF_TOKEN" \
      --data "$(jq -cn --arg query "$DEP_QUERY" '{query: $query}')" \
    )" || {
      echo "ERROR: HTTP dependency request failed for ${PACKAGE_TYPE}:${PACKAGE}@${VERSION}" >&2
      break
    }

    if jq -e '.errors and (.errors | length > 0)' >/dev/null <<< "$RESPONSE"; then
      echo "ERROR: GraphQL query failed for ${PACKAGE_TYPE}:${PACKAGE}@${VERSION}" >&2
      break
    fi

    if ! jq -e '.data.publicPackages.getPackageVersion != null' >/dev/null <<< "$RESPONSE"; then
      echo "WARNING: Package/version not found: ${PACKAGE_TYPE}:${PACKAGE}@${VERSION}" >&2
      break
    fi

    FOUND_PACKAGE=true

    # Single-pass jq filter: calculates age, expands CVE list, and writes CSV
    jq -r \
      --arg rtype "$PACKAGE_TYPE" \
      --arg rpkg "$PACKAGE" \
      --arg rver "$VERSION" \
      --argjson now "$(date +%s)" '
      .data.publicPackages.getPackageVersion.dependencies.dependenciesConnection.edges[]?.node as $dep
      | $dep.version as $verNode
      | ($verNode.publishedAt // "") as $pubRaw
      | (if $pubRaw != "" then ($pubRaw[:10]) else "" end) as $pubDate
      | (if $pubRaw != "" then
          try (
            (($pubRaw[:19] + "Z") | fromdateiso8601) as $pubEpoch
            | (($now - $pubEpoch) / 86400 | floor | tostring)
          ) catch ""
         else "" end) as $pubAgeDays
      | ($verNode.securityInfo.fixedVulnerabilitiesConnection.edges // []) as $cves
      | if ($cves | length) > 0 then
          $cves[] | [
            $rtype,
            $rpkg,
            $rver,
            $rtype,
            ($verNode.publicPackage.name // ""),
            ($verNode.version // ""),
            ($dep.isDirect | tostring),
            ($dep.path // ""),
            (.node.name // "NONE"),
            ((.node.cvss.preferredBaseScore // 0) | tostring),
            $pubDate,
            $pubAgeDays
          ]
        else
          [
            $rtype,
            $rpkg,
            $rver,
            $rtype,
            ($verNode.publicPackage.name // ""),
            ($verNode.version // ""),
            ($dep.isDirect | tostring),
            ($dep.path // ""),
            "NONE",
            "0",
            $pubDate,
            $pubAgeDays
          ]
        end
      | @csv
    ' <<< "$RESPONSE" >> "$OUTPUT_FILE"

    HAS_NEXT="$(jq -r '.data.publicPackages.getPackageVersion.dependencies.dependenciesConnection.pageInfo.hasNextPage // false' <<< "$RESPONSE")"
    [[ "$HAS_NEXT" != "true" ]] && break

    AFTER="$(jq -r '.data.publicPackages.getPackageVersion.dependencies.dependenciesConnection.pageInfo.endCursor // empty' <<< "$RESPONSE")"
    [[ -z "$AFTER" ]] && break

  done

  if [[ "$FOUND_PACKAGE" == true ]]; then
    echo "Completed: ${PACKAGE_TYPE}:${PACKAGE}@${VERSION}"
  fi

done < "$INPUT_FILE"

echo
echo "Export complete!"
echo "Output written to: $OUTPUT_FILE"
