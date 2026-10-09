# JFrog Curation Toolkit

End-to-end toolkit for the **JFrog Curation process** — list  waiver requests, manage catalog labels.

## Prerequisites

| Tool | Used by |
|------|---------|
| [curl](https://curl.se/) | All scripts |
| [jq](https://jqlang.github.io/jq/) | All scripts |
| [JFrog CLI](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli) (`jf`) | `add-label-packages.sh` (audit mode only) |

You also need:

- A JFrog Platform URL (e.g. `https://myorg.jfrog.io`)
- An access token with permissions for Xray Curation and Catalog GraphQL APIs

## Quick start

```bash
chmod +x *.sh

export JFROG_URL="https://myorg.jfrog.io"
export JFROG_TOKEN="your-access-token"
export LABEL_NAME="jfrog-waiver-policy-9"
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
- [Use npm with JFrog CLI](https://docs.jfrog.com/artifactory/docs/use-npm-with-jfrog-cli) — npm resolver configuration in more depth

## Scripts

| Script | When to use | Description | Documentation |
|--------|-------------|--------------|----------------|
| [`list-waivers.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/list-waivers.sh) | Review pending/approved/rejected waiver requests; export waiver IDs or package lists | List Curation waiver requests (pending, approved, rejected) | [docs/list-waivers.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-waivers.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-waivers-flow.md) |
| [`add-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/add-label-packages.sh) | Assign packages to a catalog label so they can be included in policy conditions. Use `--dependency` to label the direct dependency behind a transitive block instead of the blocked package itself | Create a catalog label (if needed) and assign package versions, with an optional direct-dependency mode | [docs/add-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/add-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/add-label-packages-flow.md) |
| [`list-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/list-label-packages.sh) | Audit what is currently on a label before adding or removing packages | List packages currently assigned to a label | [docs/list-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/list-label-packages-flow.md) |
| [`remove-label-packages.sh`](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/remove-label-packages.sh) | Revoke an approved waiver by removing its package from the catalog label; also clean up expired or no-longer-needed entries | Remove package versions from a label | [docs/remove-label-packages.md](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/remove-label-packages.md) · [flow](https://github.com/sumanthsv-jfrog/jfrog-curation-waiver-scripts/blob/main/docs/remove-label-packages-flow.md) |

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

| Script | API |
|--------|-----|
| `list-waivers.sh` | `GET /xray/api/v1/curation/waiver_requests` |
| Label scripts | `POST /catalog/api/v1/custom/graphql` |

## Security notes

- Do not commit access tokens or instance URLs with secrets.
- Prefer environment variables or a secrets manager over hard-coding credentials in scripts.
- Generated GraphQL mutation files may contain package names from your environment; review before sharing.

## License

Internal / team use — adjust as needed for your GitHub repository.
