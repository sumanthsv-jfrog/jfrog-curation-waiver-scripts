# add-label-packages.sh

Creates a **JFrog Catalog custom label** (if it does not exist) and assigns package versions to it using the Catalog GraphQL API.

## Usage

```bash
./add-label-packages.sh <JFROG_URL> <JFROG_TOKEN> <LABEL_NAME> [--from-file] [--dry-run] [--dependency]
```

## Arguments

| Argument | Description |
|----------|-------------|
| `JFROG_URL` | JFrog Platform base URL, e.g. `https://myorg.jfrog.io` |
| `JFROG_TOKEN` | Bearer access token |
| `LABEL_NAME` | Name of the catalog custom label to create or update |

## Options

| Flag | Description |
|------|-------------|
| `--from-file` | Skip the JFrog Curation Audit fetch and use the existing **`packages.csv`** as-is |
| `--dry-run` | Write `packages.csv` and stop — no label creation or assignment is performed |
| `--dependency` | For transitive blocks, label the **direct dependency** instead of the blocked package (see below) |

## Modes

By default (no `--from-file`), the script runs **`jf ca`** against the current project and generates `packages.csv` from the curation audit results. Pass `--from-file` to skip the audit fetch entirely and use an existing `packages.csv` you've prepared or generated another way (for example, from `list-waivers.sh`).

Either way, `packages.csv` ends up with this format (a header row is skipped if present):

```csv
name,version,type
lodash,4.17.21,npm
braces,2.3.2,npm
```

## `--dependency`

`jf curation-audit --format json` reports both the blocked package and the direct dependency that pulled it in (`direct_dependency_package_name` / `direct_dependency_package_version`). For a **direct** block these are the same package; for a **transitive** block they differ — e.g. `next` pulling in `@next/swc-linux-x64-gnu`.

`--dependency` is a **filter**, not a substitution. With it:

- Only rows where the direct dependency **differs** from the blocked package (transitive blocks) are kept.
- Rows where the direct dependency **equals** the blocked package (a direct block), or where no direct dependency was reported, are **dropped**.
- The CSV always carries the **blocked package's own** name/version — the actual package that needs to be labeled to clear the policy violation. The direct dependency is only used to decide whether to include the row; it is never written in place of the blocked package.

`--dependency` only affects the curation-audit fetch — it has no effect when combined with `--from-file`, since in that case `packages.csv` is used as-is.

```bash
# Preview which transitively-blocked packages would be labeled, without assigning anything
./add-label-packages.sh https://myorg.jfrog.io "$JFROG_TOKEN" my-label --dependency --dry-run
cat packages.csv

# Actually create/update the label, limited to transitive blocks
./add-label-packages.sh https://myorg.jfrog.io "$JFROG_TOKEN" my-label --dependency
```

**Note:** if every blocked package in the project is a direct dependency, `--dependency` will produce an empty `packages.csv` (header row only) — that's expected, not an error; it means there are no transitive blocks to label.

## What it does

1. Fetches packages — either runs `jf ca` and writes `packages.csv` from the curation audit (default), or reads the existing `packages.csv` if `--from-file` is passed
2. Exits here if `--dry-run` is set
3. Builds a GraphQL mutation from `packages.csv` → `mutation.graphql`
4. Checks whether the label already exists
5. Creates the label if missing (description defaults to `test label` in the script)
6. Executes the assign mutation to attach all listed versions to the label

## Example

```bash
# Default: fetch from JFrog Curation Audit, create/update the label
./add-label-packages.sh "$JFROG_URL" "$JFROG_TOKEN" "jfrog-waiver-policy-9"

# Use an existing packages.csv instead of running jf ca
./add-label-packages.sh "$JFROG_URL" "$JFROG_TOKEN" "jfrog-waiver-policy-9" --from-file

# Only label direct dependencies behind transitive blocks
./add-label-packages.sh "$JFROG_URL" "$JFROG_TOKEN" "jfrog-waiver-policy-9" --dependency
```

## Output files

| File | Purpose |
|------|---------|
| `packages.csv` | Package list — generated from `jf ca` by default, or provided by you with `--from-file` |
| `mutation.graphql` | Generated assign mutation (useful for review or re-run) |
| `ca.json`, `ca2.json` | Raw curation audit output (audit fetch mode only; removed at the end of a normal run) |

## Requirements

- `curl`, `jq`
- `jf` (JFrog CLI) — required unless using `--from-file`

JFrog CLI must be configured for the project's package manager before running the audit fetch (see the main [README](../README.md#configure-jfrog-cli-for-different-package-types) for `jf npm-config`, `jf mvn-config`, `jf pip-config`, and `jf dotnet-config` examples):

```bash
jf config add ...
jf npm-config --repo-resolve=rea-npm-virtual --repo-deploy=rea-npm-virtual
```

## API reference

- Catalog GraphQL: `POST {JFROG_URL}/catalog/api/v1/custom/graphql`
- Mutations used: `createCustomCatalogLabel`, `assignCustomCatalogLabelToPublicPackageVersions`

## Related scripts

- [`list-waivers.sh`](list-waivers.md) — export approved waivers to CSV
- [`list-label-packages.sh`](list-label-packages.md) — verify assignments
- [`remove-label-packages.sh`](remove-label-packages.md) — remove versions from the label

## Flow

- [Add packages to label flow](add-label-packages-flow.md)
