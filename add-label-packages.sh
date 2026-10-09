#!/bin/bash
JFROG_URL="${1:?Enter JFrog URL e.g. https://myorg.jfrog.io}"
JFROG_TOKEN="${2:?Enter JFrog Token}"
LABEL_NAME="${3:?Enter Label Name e.g. worksafe_new_label}"
LABEL_DESC="test label"
INPUT_FILE="packages.csv"
OUTPUT_FILE="mutation.graphql"
FROM_FILE=false
DRY_RUN=false
DEPENDENCY=false

# Parse optional flags
for arg in "$@"; do
  [[ "$arg" == "--from-file" ]]   && FROM_FILE=true
  [[ "$arg" == "--dry-run" ]]     && DRY_RUN=true
  [[ "$arg" == "--dependency" ]]  && DEPENDENCY=true
done

GetCAJson() {
  echo "Fetching curation audit data..."
  echo "n" | jf ca --format json > ca2.json
  sed -n '/^\[/,/^\]/p' ca2.json > ca.json

  # Print header row first
  echo "blocked_package_name,blocked_package_version,type" > "$INPUT_FILE"

  # Each row from `jf ca` carries both the blocked package AND the direct
  # dependency that pulled it in (direct_dependency_package_name/version).
  # For a transitive block these differ; for a direct block they're the same
  # (or direct_dependency fields are empty).
  #
  # --dependency: acts as a FILTER only — it keeps just the rows where the
  # direct dependency differs from the blocked package (i.e. transitive
  # blocks) and drops direct blocks (direct == blocked, or no direct
  # dependency reported). The output always emits the BLOCKED package's
  # name/version — that's the actual package that needs to be labeled to
  # clear the policy violation. The direct dependency is only used to decide
  # whether to include the row, never as a substitute value.
  #
  # Without the flag: list every blocked package, unchanged.
  cat ca.json | jq -rc --argjson dep "$DEPENDENCY" '
    .[]
    | select(
        ($dep != true)
        or (
          (.direct_dependency_package_name != null)
          and (.direct_dependency_package_name != "")
          and ( (.direct_dependency_package_name != .blocked_package_name)
                or (.direct_dependency_package_version != .blocked_package_version) )
        )
      )
    | [.blocked_package_name, .blocked_package_version, .type]
    | @csv' \
    | tr -d '"' \
    | sort -u >> "$INPUT_FILE"
}

CheckLabelExists() {
  echo "Checking if label '$LABEL_NAME' exists..."

  local query="{ customCatalogLabel { getLabel(name: \"$LABEL_NAME\") { name } } }"

  local response
  response=$(curl -s -X POST "$JFROG_URL/catalog/api/v1/custom/graphql" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')")

  # If getLabel returns a name, the label exists
  echo "$response" | jq -e '.data.customCatalogLabel.getLabel.name != null' > /dev/null 2>&1
}

CreateLabel() {
  echo "Creating label: $LABEL_NAME..."

  local query="mutation { customCatalogLabel { createCustomCatalogLabel(label: {name: \"$LABEL_NAME\", description: \"$LABEL_DESC\"}) { name description } } }"

  curl -s -X POST "$JFROG_URL/catalog/api/v1/custom/graphql" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')"
  echo ""
}

generate_mutation() {
  local source_file="${1:-$INPUT_FILE}"

  if [[ ! -f "$source_file" ]]; then
    echo "ERROR: Input file '$source_file' not found."
    exit 1
  fi

  echo "Generating mutation from: $source_file"

  {
    echo "mutation {"
    echo "  customCatalogLabel {"
    echo "    assignCustomCatalogLabelToPublicPackageVersions("
    echo "      publicPackageVersionsLabel: {"
    echo "        publicPackageVersions: ["

    local first=true
    local count=0

    while IFS=',' read -r name version type; do
      # Skip header row or empty lines
      [[ -z "$name" || "$name" == "blocked_package_name" ]] && continue

      if [ "$first" = true ]; then
        first=false
      else
        echo ","
      fi

      echo "          {publicPackage: {name: \"$name\", type: \"$type\"}, version: \"$version\"}"
      ((count++))

    done < "$source_file"

    echo ""
    echo "        ],"
    echo "        labelName: \"$LABEL_NAME\""
    echo "      }"
    echo "    )"
    echo "  }"
    echo "}"
  } > "$OUTPUT_FILE"

  echo "Mutation generated with $count package(s) -> $OUTPUT_FILE"
}

UpdateLabel() {
  echo "Assigning packages to label '$LABEL_NAME'..."

  curl -s -X POST "$JFROG_URL/catalog/api/v1/custom/graphql" \
    -H "Authorization: Bearer $JFROG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -Rs '{query: .}' "$OUTPUT_FILE")"
  echo ""
}

# ── Main flow ────────────────────────────────────────────────────────────────

if [ "$FROM_FILE" = true ]; then
  echo "Mode: reading packages from existing file -> $INPUT_FILE"
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: '$INPUT_FILE' not found. Provide a CSV with columns: name,version,type"
    exit 1
  fi
else
  echo "Mode: fetching packages from JFrog Curation Audit"
  [ "$DEPENDENCY" = true ] && echo "  (--dependency enabled: using direct dependency name/version when it differs from the blocked package)"
  GetCAJson
fi

if [ "$DRY_RUN" = true ]; then
  echo "Dry-run mode enabled. Package data saved to '$INPUT_FILE'. Exiting without creating or assigning labels."
  rm ca.json ca2.json
  exit 0
fi

generate_mutation "$INPUT_FILE"

if CheckLabelExists; then
  echo "Label '$LABEL_NAME' already exists — skipping creation, proceeding to assign packages."
else
  echo "Label '$LABEL_NAME' does not exist — creating it."
  CreateLabel
fi

UpdateLabel
echo "Done."
rm ca.json ca2.json 2> /dev/null
