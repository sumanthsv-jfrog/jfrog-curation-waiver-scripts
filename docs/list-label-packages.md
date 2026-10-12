# list-label-packages.sh

Lists packages assigned to a **JFrog Catalog custom label**, including version-scoped and package-scoped assignments, along with when each was assigned and when it expires — via the active JFrog CLI server session.

## Usage

```bash
./list-label-packages.sh <LABEL_NAME>
```

No URL or token is passed to the script — it calls the Catalog API through `jf api`, using whatever server `jf` is already configured against (`jf config add` / `jf config show`).

## Arguments

| Argument | Description |
|----------|-------------|
| `LABEL_NAME` | Name of the catalog custom label to inspect |

## Example

```bash
./list-label-packages.sh jfrog-waiver-policy-9
```

## Output

```text
Packages in label 'jfrog-waiver-policy-9':
--------------------------------
name, version, type, assigned_at, expires_at
lodash, 4.17.21, npm, 2026-10-12T05:36:55.980Z, 2026-10-13T05:36:54.000Z
braces, 2.3.2, npm, 2026-10-11T09:12:00.000Z, never
some-package, (all versions), npm, 2026-10-01T00:00:00.000Z, never
--------------------------------
```

- **Version-scoped** entries show a specific version.
- **Package-scoped** entries show `(all versions)` when the label applies to the whole package.
- `assigned_at` and `expires_at` come from the assignment's `assignmentInfo` (not a property of the package itself) — the same package can appear on multiple labels with different expiry dates.
- `expires_at` shows `never` for assignments with no expiry (permanent waiver).
- Results are de-duplicated and sorted.

## Behavior

1. Verifies the label exists (exits with an error if not found)
2. Paginates through `publicPackageVersionsConnection` (specific versions), requesting `assignmentInfo { assignedAt expirationAt }` alongside each edge
3. Paginates through `publicPackagesConnection` (whole-package assignments), same `assignmentInfo` fields
4. Prints combined, sorted output with assignment/expiry columns

## Requirements

- `jf` (JFrog CLI), configured with a default server (`jf config add`)
- `jq`

## API reference

- Catalog GraphQL: `POST /catalog/api/v1/custom/graphql`, called via `jf api /catalog/api/v1/custom/graphql`
- Fields used: `publicPackageVersionsConnection`, `publicPackagesConnection`, `assignmentInfo { assignedAt expirationAt }`

## Related scripts

- [`add-label-packages.sh`](add-label-packages.md) — assign packages to a label, with an optional expiry (`-d <days>`)
- [`remove-label-packages.sh`](remove-label-packages.md) — remove packages from a label
- [`list-waivers.sh`](list-waivers.md) — source list from Curation waivers

## Flow

- [List label packages flow](list-label-packages-flow.md)
