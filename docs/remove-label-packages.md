# remove-label-packages.sh

Removes package versions from a **JFrog Catalog custom label**. Only entries that are **currently assigned** to the label are removed; others are skipped with a message.

Approved waivers are enforced via catalog labels — removing a package from the waiver label **revokes** that waiver and the package is subject to curation policy again.

## Usage

```bash
./remove-label-packages.sh <JFROG_URL> <JFROG_TOKEN> <LABEL_NAME> [input.csv]
```

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `JFROG_URL` | JFrog Platform base URL | — |
| `JFROG_TOKEN` | Bearer access token | — |
| `LABEL_NAME` | Catalog custom label name | — |
| `input.csv` | CSV file with packages to remove | `packages.csv` |

## Input CSV format

```csv
name,version,type
lodash,4.17.21,npm
braces,2.3.2,npm
```

Header row (`name,version,type`) and blank lines are ignored.

## Example

```bash
./remove-label-packages.sh "$JFROG_URL" "$JFROG_TOKEN" "jfrog-waiver-policy-9" packages.csv
```

## What it does

1. Confirms the label exists
2. Fetches all packages currently assigned to the label (paginated)
3. Reads the input CSV and builds a remove mutation only for entries that match label membership
4. Writes `remove-mutation.graphql`
5. Executes the mutation

Packages in the CSV that are **not** on the label are skipped:

```text
SKIP (not in label): npm/foo@1.0.0
```

If nothing matches, the script exits successfully without calling the remove API.

## Output files

| File | Purpose |
|------|---------|
| `remove-mutation.graphql` | Generated remove mutation for review or debugging |

## Requirements

- `curl`
- `jq`

## API reference

- Catalog GraphQL: `POST {JFROG_URL}/catalog/api/v1/custom/graphql`
- Mutation used: `removeCustomCatalogLabelFromPublicPackageVersions`

## Related scripts

- [`list-label-packages.sh`](list-label-packages.md) — see what is currently on the label
- [`add-label-packages.sh`](add-label-packages.md) — assign packages to a label
- [`list-waivers.sh`](list-waivers.md) — export waiver packages to CSV

## Flow

- [Remove packages from label flow](remove-label-packages-flow.md)
