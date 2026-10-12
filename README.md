# JFrog Curation Toolkit

End-to-end toolkit for the **JFrog Curation process** — list waiver requests, manage catalog labels.

## Prerequisites

| Tool | Used by |
|------|---------|
| [curl](https://curl.se/) | `list-waivers.sh` |
| [jq](https://jqlang.github.io/jq/) | All scripts |
| [JFrog CLI](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli) (`jf`) | `add-label-packages.sh`, `list-label-packages.sh`, `remove-label-packages.sh` |

You also need:

- A JFrog Platform URL (e.g. `https://myorg.jfrog.io`) and an access token with permissions for the Xray Curation API — for `list-waivers.sh`
- A JFrog CLI server already configured (`jf config add`) — for the label scripts

## Quick start

`list-waivers.sh` takes the platform URL and token as explicit arguments:

```bash
chmod +x *.sh

export JFROG_URL="https://myorg.jfrog.io"
export JFROG_TOKEN="your-access-token"
```

The **label scripts** (`add-label-packages.sh`, `list-label-packages.sh`, `remove-label-packages.sh`) take neither — they use the active JFrog CLI server session instead. Configure it once:

```bash
jf config add my-server --url=https://myorg.jfrog.io --access-token=your-access-token
jf config use my-server
```

From then on, the label scripts only need a label name:

```bash
./list-label-packages.sh jfrog-waiver-policy-9
```

## Configure JFrog CLI for Different Package Types

`add-label-packages.sh` (audit mode) runs `jf ca`, which resolves dependencies through a package-manager-specific resolver. Before running it for a given ecosystem, configure that resolver once per project using the matching `jf <tool>-config` command. Run `jf config add` first to register your JFrog Platform server if you haven't already.

| Package type | Config command | Alias |
|--------------|-----------------|-------|
| npm | `jf npm-config --repo-resolve=rea-npm-virtual --repo-deploy=rea-npm-virtual` | `jf npmc` |
| Maven | `jf mvn-config --repo-resolve-releases=rea-maven-virtual --repo-resolve-snapshots=rea-maven-virtual` | `jf mvnc` |
| PyPI | `jf pip-config --repo-resolve=rea-pypi-virtual` | `jf pipc` |
| NuGet / .NET | `jf dotnet-config --repo-resolve=rea-nuget-virtual` | `jf dotnetc` |

Replace the repo names above (`rea-npm-virtual`, etc.) with your own virtual repositories. Each config command writes a project-level config file (e.g. `.jfrog/projects/npm.yaml`) that `jf ca` and the package manager's native install command both read — run it once per project, before the first `jf ca` or build.

### Reference

- [JFrog CLI Command Reference](https://docs.jfrog.com/integrations/docs/jfrog-cli-command-reference) — full flag reference for `jf npm-config`, `jf mvn-config`, `jf pip-config`, `jf dotnet-config`, and other build-tool config commands
- [Curation Compliance Check](https://docs.jfrog.com/security/docs/curation-compliance-check) — `jf curation-audit` (`jf ca`) usage, supported package types, and waiver creation from the CLI
- [Use API Endpoints via CLI](https://docs.jfrog.com/integrations/docs/use-api-endpoints-via-cli) — `jf api`, used by all three label scripts to call the Catalog GraphQL endpoint through the active CLI session
- [Use npm with JFrog CLI](https://docs.jfrog.com/artifactory/docs/use-npm-with-jfrog-cli) — npm resolver configuration in more depth

## Scripts

| Script | When to use | Description | Documentation |
|--------|-------------|--------------|----------------|
| [`list-waivers.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/list-waivers.sh) | Review pending/approved/rejected waiver requests; export waiver IDs or package lists | List Curation waiver requests (pending, approved, rejected) | [docs/list-waivers.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-waivers.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-waivers-flow.md) |
| [`add-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/add-label-packages.sh) | Assign packages to a catalog label, optionally with an expiry date. Use `--dependency` to only label transitively-blocked packages (skipping direct blocks) | Create a catalog label (if needed) and assign package versions, with an optional expiry and direct-dependency filter | [docs/add-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/add-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/add-label-packages-flow.md) |
| [`list-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/list-label-packages.sh) | Audit what is currently on a label — including when it was assigned and when it expires — before adding or removing packages | List packages currently assigned to a label, with assignment and expiry timestamps | [docs/list-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-label-packages-flow.md) |
| [`remove-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/remove-label-packages.sh) | Revoke an approved waiver by removing its package from the catalog label; also clean up expired or no-longer-needed entries | Remove package versions from a label (only if currently assigned) | [docs/remove-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/remove-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/remove-label-packages-flow.md) |

See [docs/flows.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/flows.md) for an overview of all flows and the end-to-end waiver → label workflow.

## CSV format

Scripts that read or write package lists expect three columns:

```
name,version,type
lodash,4.17.21,npm
requests,2.31.0,pypi
```

- **name** — package name (e.g. `lodash`, `@scope/pkg`)
- **version** — exact version string
- **type** — package type (e.g. `npm`, `pypi`, `maven`, `docker`)

A header row (`name,version,type`, or the older `blocked_package_name,...`) is recognized and skipped **only on the first line** of the file — a package that happens to be named `name` on a later line is treated as real data, not a header.

`list-waivers.sh` outputs additional columns beyond these three.

## Generated files

These files are created at runtime and are safe to delete or add to `.gitignore`:

| File | Created by |
|------|-------------|
| `packages.csv` | Input for label scripts |
| `mutation.graphql` | `add-label-packages.sh` |
| `remove-mutation.graphql` | `remove-label-packages.sh` |
| `ca.json`, `ca2.json` | `add-label-packages.sh` (audit mode) |

## API endpoints

| Script | API | Called via |
|--------|-----|------------|
| `list-waivers.sh` | `GET /xray/api/v1/curation/waiver_requests` | `curl` with `JFROG_URL` / `JFROG_TOKEN` |
| `add-label-packages.sh`, `list-label-packages.sh`, `remove-label-packages.sh` | `POST /catalog/api/v1/custom/graphql` | `jf api` using the active JFrog CLI server session |

## Security notes

- Do not commit access tokens or instance URLs with secrets.
- Prefer environment variables or a secrets manager over hard-coding credentials in scripts.
- For the label scripts, credentials never appear in the script invocation at all — they live only in `jf`'s own config, set once via `jf config add`.
- Avoid passing tokens on the command line for `list-waivers.sh`; read them into a variable instead (`read -rs JFROG_TOKEN`) so they don't end up in shell history.
- Generated GraphQL mutation files may contain package names from your environment; review before sharing.

## License

Internal / team use — adjust as needed for your GitHub repository.
