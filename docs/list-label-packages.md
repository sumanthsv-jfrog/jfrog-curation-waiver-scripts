# list-label-packages.sh

Lists packages assigned to a **JFrog Catalog custom label**, including version-scoped and package-scoped assignments.

## Usage

```bash
./list-label-packages.sh <JFROG_URL> <JFROG_TOKEN> <LABEL_NAME>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `JFROG_URL` | JFrog Platform base URL, e.g. `https://myorg.jfrog.io` |
| `JFROG_TOKEN` | Bearer access token |
| `LABEL_NAME` | Name of the catalog custom label to inspect |

## Example

```bash
./list-label-packages.sh "$JFROG_URL" "$JFROG_TOKEN" "jfrog-waiver-policy-9"
```

## Output

```text
Packages in label 'jfrog-waiver-policy-9':
--------------------------------
name, version, type
lodash, 4.17.21, npm
braces, 2.3.2, npm
some-package, (all versions), npm
--------------------------------
```

- **Version-scoped** entries show a specific version.
- **Package-scoped** entries show `(all versions)` when the label applies to the whole package.
- Results are de-duplicated and sorted.

## Behavior

1. Verifies the label exists (exits with an error if not found)
2. Paginates through `publicPackageVersionsConnection` (specific versions)
3. Paginates through `publicPackagesConnection` (whole-package assignments)
4. Prints combined, sorted output

## Requirements

- `curl`
- `jq`

## API reference

- Catalog GraphQL: `POST {JFROG_URL}/catalog/api/v1/custom/graphql`

## Related scripts

- [`add-label-packages.sh`](add-label-packages.md) — assign packages to a label
- [`remove-label-packages.sh`](remove-label-packages.md) — remove packages from a label
- [`list-waivers.sh`](list-waivers.md) — source list from Curation waivers

## Flow

- [List label packages flow](list-label-packages-flow.md)
