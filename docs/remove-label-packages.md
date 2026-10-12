# remove-label-packages.sh

Removes package versions from a **JFrog Catalog custom label**, via the active JFrog CLI server session. Only entries that are **currently assigned** to the label are removed; others are skipped with a message.

Approved waivers are enforced via catalog labels — removing a package from the waiver label **revokes** that waiver and the package is subject to curation policy again.

## Usage

```bash
./remove-label-packages.sh <LABEL_NAME> [input.csv]
```

No URL or token is passed to the script — it calls the Catalog API through `jf api`, using whatever server `jf` is already configured against (`jf config add` / `jf config show`).

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `LABEL_NAME` | Catalog custom label name | — |
| `input.csv` | CSV file with packages to remove | `packages.csv` |

## Input CSV format

```csv
name,version,type
lodash,4.17.21,npm
braces,2.3.2,npm
```

A header row (`name,version,type`, or the older `blocked_package_name,...`) is recognized and skipped **only on the first line** of the file. A package genuinely named `name` on a later line (for example, if you're cleaning up a bad entry created by a header-row bug elsewhere) is treated as real data, not a header, and will be removed correctly.

## Example

```bash
./remove-label-packages.sh jfrog-waiver-policy-9 packages.csv
```

## What it does

1. Confirms the label exists (`jf api`)
2. Fetches all packages currently assigned to the label (paginated, `jf api`)
3. Reads the input CSV and builds a remove mutation only for entries that match label membership
4. Writes `remove-mutation.graphql`
5. Executes the mutation (`jf api`)

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

- `jf` (JFrog CLI), configured with a default server (`jf config add`)
- `jq`

## API reference

- Catalog GraphQL: `POST /catalog/api/v1/custom/graphql`, called via `jf api /catalog/api/v1/custom/graphql`
- Mutation used: `removeCustomCatalogLabelFromPublicPackageVersions`

## Related scripts

- [`list-label-packages.sh`](list-label-packages.md) — see what is currently on the label, including expiry
- [`add-label-packages.sh`](add-label-packages.md) — assign packages to a label
- [`list-waivers.sh`](list-waivers.md) — export waiver packages to CSV

## Flow

- [Remove packages from label flow](remove-label-packages-flow.md)
