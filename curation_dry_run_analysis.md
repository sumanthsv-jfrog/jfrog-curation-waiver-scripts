# Curation Dry-Run Bypass Analysis

`curation_dry_run_analysis.sh` finds packages that JFrog Curation policies **in dry-run mode** would have blocked, looks each one up in the JFrog Catalog, and reports whether it would be **allowed**, **bypassed** (fixes a high-CVSS CVE), or **need a waiver** once the policy is enforced.

## How it works

1. **Audit** – calls the Curation audit API (`/xray/api/v1/curation/audit/packages`) with `action=blocker&dry_run=true`, paging 1000 rows at a time. Ranges longer than 7 days are split into 7-day windows (API limit: 168 hours).
2. **Filter** – keeps policy entries with `dry_run: true` and `result: Blocked` (ignores `Bypassed`, `Waived`, `Approved`), optionally for one policy, deduplicated by type/name/version.
3. **Catalog** – queries the Catalog GraphQL API (`/catalog/api/v1/public/graphql`) for each package's publish date and fixed CVEs with CVSS scores.
4. **Verdict** – age is measured from publish date to the first audit request:

| Verdict | Rule |
|---|---|
| `ALLOWED_AGE` | age ≥ `MIN_AGE_DAYS` |
| `BYPASS_CVSS_FIX` | younger, but fixes a CVE with CVSS ≥ `CVSS_THRESHOLD` |
| `WAIVER_NEEDED` | younger and no qualifying CVE fix |
| `UNKNOWN_NOT_IN_CATALOG` | package/version not found in Catalog |

## Requirements

- `bash`, `curl`, `jq`
- A JFrog access token with Curation audit and Catalog read access

```sh
export JF_URL="https://<your-instance>.jfrog.io"
export JF_TOKEN="<access-token>"
```

## Usage

```sh
bash curation_dry_run_analysis.sh [--policy NAME] [--from DATE] [--to DATE] [--param K=V]
```

| Option | Description |
|---|---|
| `--policy NAME` | Only include hits from this policy |
| `--from DATE` | Start of range, `YYYY-MM-DD` or RFC 3339 (API default: 7 days ago) |
| `--to DATE` | End of range, `YYYY-MM-DD` or RFC 3339 (API default: now) |
| `--param K=V` | Extra audit API query parameter (repeatable) |

| Env variable | Default | Description |
|---|---|---|
| `MIN_AGE_DAYS` | `7` | Package age at which it's allowed |
| `CVSS_THRESHOLD` | `7.0` | Minimum CVSS of a fixed CVE to bypass |
| `AUDIT_ACTION` | `blocker` | `action=` value sent in dry-run mode |
| `PAGE_SIZE` | `1000` | Audit rows per request |
| `CATALOG_URL` | `$JF_URL/catalog/api/v1/public/graphql` | Catalog GraphQL endpoint |

### Examples

```sh
# Last 7 days, all dry-run policies
bash curation_dry_run_analysis.sh

# Last month for one policy
bash curation_dry_run_analysis.sh --policy sum_ubank_immature-srtict \
  --from "$(date -v-1m +%Y-%m-%d)" --to "$(date +%Y-%m-%d)"

# Match a 30-day / CVSS 9 immaturity condition
MIN_AGE_DAYS=30 CVSS_THRESHOLD=9 bash curation_dry_run_analysis.sh --policy <policy-name>
```

## Output

| File | Contents |
|---|---|
| `dry_run_packages.csv` | Type, name, version, first seen, request count, policies, conditions, results |
| `dry_run_vulnerabilities.csv` | One row per fixed CVE; same 12-column layout as `get-dependencies.sh`, so it works with `analyze_policy_bypass.sh` |
| `dry_run_bypass_report.csv` | Per-package publish date, age, max fixed CVSS, qualifying CVEs, verdict |

A table and a JSON summary are also printed:

```json
{
  "rule": "allowed if age >= 7d, bypassed if younger but fixes CVSS >= 7.0",
  "total_packages": 12,
  "allowed_by_age": 3,
  "bypassed_due_to_cvss_fix": 4,
  "waivers_needed": 5,
  "not_found_in_catalog": 0,
  "bypass_and_allow_percentage": 58.33
}
```

## Troubleshooting

- **`Packages found: 0`** – the script prints a `policy | dry_run | result` breakdown. Check the policy name and that it shows `dry_run=true`.
- **`Error parsing value ... created_at_start`** – use `YYYY-MM-DD` or RFC 3339 (`2026-10-02T00:00:00Z`).
- **`Maximum allowed duration is 168 hours`** – handled automatically by 7-day windows; update the script if you see it.
- **`UNKNOWN_NOT_IN_CATALOG`** – the package isn't in the public Catalog (private or misnamed package).
