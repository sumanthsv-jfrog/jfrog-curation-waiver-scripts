# JFrog Catalog Dependency & Vulnerability Policy Analyzer

A Bash utility to evaluate software dependencies against organizational package policies—specifically analyzing package release maturity (e.g., 7-day age policy) and vulnerability bypass rules (CVSS ≥ 7.0 fixes) using the JFrog Catalog GraphQL API.

---

## Table of Contents

- [Overview](#overview)
- [Policy Rules Analyzed](#policy-rules-analyzed)
- [Prerequisites](#prerequisites)
- [Installation & Setup](#installation--setup)
- [Input File Format](#input-file-format)
- [Usage](#usage)
- [Output Data Schema](#output-data-schema)
- [Analysis & Metrics Calculation](#analysis--metrics-calculation)
- [Package Type Format Reference](#package-type-format-reference)
- [Troubleshooting](#troubleshooting)

---

## Overview

When updating software dependencies, security policies often enforce an **Immature Package Policy** (e.g., delaying package adoption for 7 days after publication to reduce supply chain attack risks). However, security teams often permit an immediate **CVSS Bypass** if a new release resolves a Critical or High severity vulnerability ($CVSS \ge 7.0$).

This tool automates the process by:
1. Parsing an input CSV list of root packages.
2. Querying the JFrog Catalog GraphQL API (`/onemodel/api/v1/graphql`) to extract the complete dependency tree in a single query pass.
3. Extracting metadata for each dependency: `publishedAt` release timestamps and fixed vulnerability CVSS scores.
4. Exporting structured CSV results ready for automated policy analysis and waiver reporting.

---

## Policy Rules Analyzed

| Package Age | Fixes CVSS $\ge$ 7.0? | Policy Result | Action Required |
| :--- | :--- | :--- | :--- |
| **$\ge$ 7 Days** | *Any* | **Allowed** | No waiver needed (passes age maturity policy). |
| **$<$ 7 Days** | **Yes** | **Bypassed (Allowed)** | No waiver needed (CVSS 7+ fix overrides age restriction). |
| **$<$ 7 Days** | **No** | **Blocked** | **Waiver Required** (immature package without high severity fix). |

---

## Prerequisites

Ensure the following system dependencies are installed:

- **Bash** (v4.0 or higher)
- **`curl`** (HTTP client with `--fail-with-body` support)
- **`jq`** (Command-line JSON processor)

Verify installation:
```bash
curl --version
jq --version
```

---

## Installation & Setup

1. Clone or copy the script to your environment:
   ```bash
   chmod +x export_dependencies_vulnerabilities.sh
   chmod +x analyze_policy_bypass.sh
   ```

2. Set required environment variables:
   ```bash
   export JF_URL="https://your-instance.jfrog.io"
   export JF_TOKEN="your_jfrog_access_token"
   ```

---

## Input File Format

Create an input CSV file (default: `packages.csv`) listing the root packages you wish to audit.

```csv
packagetype,packagename,version
npm,@nestjs/core,10.3.0
maven,org.springframework.boot:spring-boot-starter-web,3.2.0
pypi,requests,2.31.0
```

> **Note:** The header row `packagetype,packagename,version` is automatically detected and skipped.

---

## Usage

### Step 1: Export Dependencies & Vulnerabilities

Run the main extraction script:

```bash
./export_dependencies_vulnerabilities.sh [input_csv] [output_csv]
```

**Example:**
```bash
./export_dependencies_vulnerabilities.sh packages.csv dependencies_vulnerabilities.csv
```

### Step 2: Analyze Policy & Calculate Waivers

Run the analysis script against the exported CSV output:

```bash
./analyze_policy_bypass.sh dependencies_vulnerabilities.csv
```

---

## Output Data Schema

The generated CSV contains the following columns:

| Column Name | Description |
| :--- | :--- |
| `root_package_type` | Ecosystem/type of the requested input package (e.g., `npm`, `maven`). |
| `root_package_name` | Name of the root package being analyzed. |
| `root_package_version` | Version of the root package. |
| `package_type` | Ecosystem/type of the dependency package. |
| `package_name` | Name of the dependency package. |
| `package_version` | Resolved version of the dependency package. |
| `is_direct` | `true` if a direct dependency; `false` if transitive. |
| `path` | Transitive dependency graph path. |
| `fixed_cve_names` | CVE ID resolved by this version (e.g., `CVE-2024-12345`) or `NONE`. |
| `cvss_score` | Preferred CVSS base score of the fixed vulnerability. |
| `published_at` | Release date formatted as `YYYY-MM-DD`. |
| `published_age_days` | Number of days elapsed since publication. |

---

## Analysis & Metrics Calculation

The `analyze_policy_bypass.sh` script evaluates the generated dataset and produces a summary JSON report:

```json
{
  "total_packages_evaluated": 50,
  "packages_allowed_without_waiver": 48,
  "packages_bypassed_due_to_cvss7_plus": 3,
  "waivers_needed_to_be_raised": 2,
  "bypass_and_allow_percentage": 96.00
}
```

### Interpretation:
- **`packages_bypassed_due_to_cvss7_plus`**: Packages under 7 days old that avoided blocking because they resolve a High/Critical CVE.
- **`waivers_needed_to_be_raised`**: Packages under 7 days old carrying no CVSS 7+ fix that require manual security waiver approval.
- **`bypass_and_allow_percentage`**: Total proportion of updates that can proceed automatically without manual intervention.

---

## Package Type Format Reference

When populating `packages.csv`, adhere to ecosystem-specific naming rules required by the JFrog Catalog GraphQL API:

| Package Type | Name Format | Example | Note |
| :--- | :--- | :--- | :--- |
| **`npm`** | `[@scope/]name` | `@nestjs/core`, `react` | Must include `@` and `/` for scoped packages. |
| **`maven`** | `groupId:artifactId` | `org.apache.commons:commons-lang3` | **Must** use colon `:` separator. |
| **`pypi`** | Canonical name | `pillow`, `requests` | Use PyPI canonical lowercase names. |
| **`nuget`** | Package ID | `Newtonsoft.Json` | Matches standard NuGet Package ID. |
| **`go`** | Module Path | `github.com/gin-gonic/gin` | Full module path without `https://`. |

---

## Troubleshooting

### Issue: Package/version not found (`WARNING: Package/version not found`)
- Verify `JF_URL` and `JF_TOKEN` credentials.
- Ensure Maven package names follow `groupId:artifactId` format.
- Ensure package scopes for `npm` are URL/GraphQL compliant.

### Issue: `jq: error: fromdateiso8601` failure
- Ensure your `jq` version is 1.6 or higher to support ISO-8601 date parsing.

### Issue: Authentication Failure (`HTTP 401 / 403`)
- Verify that your access token is active and possesses read permissions for the JFrog Catalog (`onemodel`) service.% 
