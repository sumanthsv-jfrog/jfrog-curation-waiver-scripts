# list-waivers.sh

Lists JFrog Curation **waiver requests** — packages that developers asked to unblock after Curation blocked them.

## Usage

```bash
./list-waivers.sh <JFROG_URL> <JFROG_TOKEN> [options]
```

Run `./list-waivers.sh -h` for built-in help.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--status <value>` | Filter by status: `pending`, `approved`, `rejected`, or `all` | `pending` |
| `--pkg-type <type>` | Filter by package type (e.g. `npm`, `pypi`) | — |
| `--pkg-name <name>` | Filter by package name | — |
| `--pkg-version <version>` | Filter by package version | — |
| `--can-approve` | Only requests the current user can approve | off |
| `--rows <n>` | Page size for API pagination | `50` |
| `--csv` | CSV output (default) | on |
| `--json` | Raw JSON output | off |
| `-h`, `--help` | Show help | — |

## Output

### CSV (default)

Header:

```text
name,version,type,status,id,repo_key,created_at,closed_at,waiver_expiry,waiver_expiry_status,requesters
```

The first three columns (`name`, `version`, `type`) match the format expected by the label scripts.

Multiple requesters on one waiver are de-duplicated and joined with `;`.

### Summary line

A count is printed to **stderr** when the script finishes:

```text
Listed 42 waiver request(s) (status=approved).
```

If the API reports a total that does not match what was fetched, a warning is printed.

## Examples

```bash
# Pending waivers (default)
./list-waivers.sh "$JFROG_URL" "$JFROG_TOKEN"

# Approved waivers only
./list-waivers.sh "$JFROG_URL" "$JFROG_TOKEN" --status approved

# All statuses
./list-waivers.sh "$JFROG_URL" "$JFROG_TOKEN" --status all

# Build packages.csv for label assignment
./list-waivers.sh "$JFROG_URL" "$JFROG_TOKEN" --status approved \
  | tail -n +2 | cut -d, -f1-3 | sort -u > packages.csv

# Inspect raw API response
./list-waivers.sh "$JFROG_URL" "$JFROG_TOKEN" --status approved --json
```

## Notes

- **Default is `pending`**, not all waivers. Use `--status approved` or `--status all` if you expect closed or approved requests.
- Pagination uses `page_num` and checks `meta.total_count` from the API response.
- Requires `curl` and `jq`.

## API reference

- [List waiver requests](https://docs.jfrog.com/security/reference/listwaiverrequests)
- Endpoint: `GET {JFROG_URL}/xray/api/v1/curation/waiver_requests`

## Flow

- [List waiver requests flow](list-waivers-flow.md)
- [Approve / reject flow](approve-reject-waivers-flow.md)
