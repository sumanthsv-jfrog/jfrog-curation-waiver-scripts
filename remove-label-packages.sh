#!/bin/bash
#
# remove-label-packages.sh
#
# Removes package versions from a JFrog Catalog custom label.
# Reads a CSV with columns:  name,version,type
# (the same format produced by the list script), and removes each entry
# from the label — but only if it is currently assigned to the label.
#
# Usage:
#   ./remove-label-packages.sh <JFROG_URL> <JFROG_TOKEN> <LABEL_NAME> [input.csv]
#
# Requires: curl, jq
#
set -euo pipefail

JFROG_URL="${1:?Enter JFrog URL e.g. https://myorg.jfrog.io}"
JFROG_TOKEN="${2:?Enter JFrog Token}"
LABEL_NAME="${3:?Enter Label Name e.g. worksafe_new_label}"
INPUT_FILE="${4:-packages.csv}"
OUTPUT_FILE="remove-mutation.graphql"

GRAPHQL_ENDPOINT="$JFROG_URL/catalog/api/v1/custom/graphql"

# ── Helper: run a GraphQL query/mutation ──────────────────────────────────────

run_query() {
  local query="$1"
  curl -s -X POST "$GRAPHQL_ENDPOINT" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')"
}

# ── Check the label exists ────────────────────────────────────────────────────

CheckLabelExists() {
  echo "Checking if label '$LABEL_NAME' exists..."
  local query="{ customCatalogLabel { getLabel(name: \"$LABEL_NAME\") { name } } }"
  local response
  response=$(run_query "$query")
  echo "$response" | jq -e '.data.customCatalogLabel.getLabel.name != null' > /dev/null 2>&1
}

# ── Fetch the versions currently assigned to the label ────────────────────────
# Emits one "type|name|version" line per assigned version, used as a membership set.

FetchLabelMembership() {
  local cursor="null"
  local has_next="true"
  local conn=".data.customCatalogLabel.getLabel.publicPackageVersionsConnection"

  while [[ "$has_next" == "true" ]]; do
    local after_arg=""
    [[ "$cursor" != "null" ]] && after_arg="after: \"$cursor\""

    local query="{ customCatalogLabel { getLabel(name: \"$LABEL_NAME\") {
      publicPackageVersionsConnection(first: 100 $after_arg) {
        edges { node { publicPackage { name type } version } }
        pageInfo { hasNextPage endCursor }
      }
    } } }"

    local response
    response=$(run_query "$query")

    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
      echo "GraphQL error while reading label membership:" >&2
      echo "$response" | jq '.errors' >&2
      exit 1
    fi

    echo "$response" | jq -r "${conn}.edges[]?.node
      | \"\(.publicPackage.type)|\(.publicPackage.name)|\(.version)\""

    has_next=$(echo "$response" | jq -r "${conn}.pageInfo.hasNextPage // false")
    cursor=$(echo "$response" | jq -r "${conn}.pageInfo.endCursor // \"null\"")
  done
}

# ── Build the remove mutation from the CSV, filtered by membership ────────────

generate_remove_mutation() {
  local source_file="$1"

  if [[ ! -f "$source_file" ]]; then
    echo "ERROR: Input file '$source_file' not found." >&2
    exit 1
  fi

  echo "Reading current packages assigned to '$LABEL_NAME'..."
  local membership
  membership=$(FetchLabelMembership)

  echo "Generating remove mutation from: $source_file"

  local count=0
  local skipped=0
  local first=true

  {
    echo "mutation {"
    echo "  customCatalogLabel {"
    echo "    removeCustomCatalogLabelFromPublicPackageVersions("
    echo "      publicPackageVersionsLabel: {"
    echo "        labelName: \"$LABEL_NAME\""
    echo "        publicPackageVersions: ["

    while IFS=',' read -r name version type; do
      # Trim surrounding whitespace from each field (CSV may use ", " separators)
      name="$(echo "$name" | xargs)"
      version="$(echo "$version" | xargs)"
      type="$(echo "$type" | xargs)"

      # Skip header row and blank lines
      [[ -z "$name" || "$name" == "name" ]] && continue

      # Only remove if this exact entry is in the label
      if ! grep -Fxq "${type}|${name}|${version}" <<< "$membership"; then
        echo "  SKIP (not in label): $type/$name@$version" >&2
        ((skipped++)) || true
        continue
      fi

      if [ "$first" = true ]; then
        first=false
      else
        echo ","
      fi

      printf '          {publicPackage: {name: "%s", type: "%s"}, version: "%s"}' \
        "$name" "$type" "$version"
      ((count++)) || true

    done < "$source_file"

    echo ""
    echo "        ]"
    echo "      }"
    echo "    )"
    echo "  }"
    echo "}"
  } > "$OUTPUT_FILE"

  echo "Mutation generated: $count package(s) to remove, $skipped skipped -> $OUTPUT_FILE"

  # Nothing to do
  if [[ "$count" -eq 0 ]]; then
    echo "No matching packages found in label — nothing to remove."
    exit 0
  fi
}

# ── Execute the remove mutation ───────────────────────────────────────────────

RemoveFromLabel() {
  echo "Removing packages from label '$LABEL_NAME'..."
  local response
  response=$(curl -s -X POST "$GRAPHQL_ENDPOINT" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -Rs '{query: .}' "$OUTPUT_FILE")")

  echo "$response" | jq '.' 2>/dev/null || echo "$response"

  if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Removal returned errors (see above)." >&2
    exit 1
  fi
}

# ── Main flow ─────────────────────────────────────────────────────────────────

if ! CheckLabelExists; then
  echo "Label '$LABEL_NAME' does not exist — nothing to remove."
  exit 1
fi

generate_remove_mutation "$INPUT_FILE"
RemoveFromLabel
echo "Done."
