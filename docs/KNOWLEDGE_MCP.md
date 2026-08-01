# Local Codebase Knowledge MCP Server

## Purpose

`openemr-eks-mcp` is a strictly read-only, local Model Context Protocol (MCP)
server for the OpenEMR on EKS repository. It provides a small curated topic
catalog, dynamic version information, bounded lexical search, safe text reads,
and risk-labelled explanations of project commands.

The server is intended to help an MCP client answer repository questions without
granting it shell, Git, AWS, Kubernetes, Terraform, Helm, or write access.

## Capabilities and non-capabilities

The server can:

- explain deployment, architecture and EKS Auto Mode, security, monitoring,
  backup/restore/DR, credential rotation, versions, CI/CD, testing,
  troubleshooting, cleanup, and OpenEMR initialization;
- search approved local source, configuration, and documentation text with
  deterministic lexical ranking;
- read a bounded line range from an approved repository file;
- parse `versions.yaml` at request time and identify a bounded set of consumer
  paths;
- explain documented operational commands and label destructive, cloud,
  cost, active-context, and network prerequisites.

The server cannot:

- execute a returned command or start a subprocess;
- write, create, update, or delete repository files;
- perform Git operations;
- make network requests;
- call AWS, Kubernetes, Terraform, Helm, or another external system;
- inspect a live cluster or validate active cloud state;
- serve HTTP. The supported transport is STDIO.

Command results are explanations, not approvals to run those commands.
The installed CLI is the supported production entry point. It pins
`transport="stdio"`, ignores FastMCP dotenv configuration, and prevents
`FASTMCP_TRANSPORT` from switching it to an HTTP listener. It also disables
FastMCP's startup banner and update checks because the banner otherwise contacts
a package index and writes a user cache.

## Install and run

Python 3.11 or newer and
[uv](https://docs.astral.sh/uv/getting-started/installation/) are required.

From the repository root, run the package directly:

```bash
uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root .
```

The first `uvx` installation may download the pinned package dependencies.
After installation, normal server operation performs no network access. Use a
pre-populated uv cache or project environment when installation itself must be
offline.

Validate configuration without starting STDIO:

```bash
uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root . --check
```

Show the installed package version:

```bash
uvx --from ./tools/codebase-mcp openemr-eks-mcp --version
```

The root can instead be supplied through the environment:

```bash
OPENEMR_EKS_REPO_ROOT=/absolute/path/to/openemr-on-eks \
  uvx --from /absolute/path/to/openemr-on-eks/tools/codebase-mcp \
  openemr-eks-mcp
```

If neither `--repo-root` nor `OPENEMR_EKS_REPO_ROOT` is set, the CLI searches
from the current directory upward for `versions.yaml` and project markers.

### Run from a Git subdirectory

Use a reviewed immutable revision when possible:

```bash
uvx \
  --from "git+https://github.com/<ORG>/<REPOSITORY>.git@<REVISION>#subdirectory=tools/codebase-mcp" \
  openemr-eks-mcp \
  --repo-root /absolute/path/to/openemr-on-eks
```

The Git source installs the server package. `--repo-root` still points to the
local checkout whose content the server may read. Package installation can use
the network; normal server operation does not.

## Cursor configuration

Cursor's current configuration reference is
[Model Context Protocol (MCP)](https://cursor.com/docs/mcp).

### 1. Validate the exact local command

From the repository root:

```bash
command -v uvx
uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root . --check
```

The check must return JSON with `"ok": true`, `"read_only": true`, and
`"transport": "STDIO"`. Copy the absolute path returned by `command -v uvx`;
Cursor launched from the macOS GUI may not inherit the same `PATH` as a shell.

### 2. Choose configuration scope

- **Project scope**: `.cursor/mcp.json` in the repository. Use this when the
  server should be available only while this project is open.
- **User scope**: `~/.cursor/mcp.json`. Use this when the same server should be
  available in every Cursor workspace on this machine.

If the selected JSON file already contains other servers, merge this entry into
its existing `mcpServers` object instead of replacing the file.

### 3. Add the STDIO server

For project scope, replace the `uvx` placeholder with the absolute path from
`command -v uvx`. Cursor resolves `${workspaceFolder}` to the repository that
contains `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "openemr-eks-knowledge": {
      "type": "stdio",
      "command": "<ABSOLUTE_PATH_TO_UVX>",
      "args": [
        "--from",
        "${workspaceFolder}/tools/codebase-mcp",
        "openemr-eks-mcp",
        "--repo-root",
        "${workspaceFolder}"
      ]
    }
  }
}
```

For example, `<ABSOLUTE_PATH_TO_UVX>` may be `/opt/homebrew/bin/uvx` on an
Apple Silicon Homebrew installation. Keep each argument as a separate JSON
array element so paths containing spaces are passed correctly.

For user scope, use absolute repository paths because the server always reads
this specific checkout:

```json
{
  "mcpServers": {
    "openemr-eks-knowledge": {
      "type": "stdio",
      "command": "<ABSOLUTE_PATH_TO_UVX>",
      "args": [
        "--from",
        "<REPOSITORY_PATH>/tools/codebase-mcp",
        "openemr-eks-mcp",
        "--repo-root",
        "<REPOSITORY_PATH>"
      ]
    }
  }
}
```

Do not commit a project configuration containing a personal absolute path.
Do not put AWS credentials, tokens, kubeconfigs, or other secrets in this
configuration.

### 4. Start and verify it in Cursor

1. Save the JSON at one of the configuration paths above.
2. Reload the Cursor window or restart Cursor so the configuration is read.
3. Open **Customize** in the Cursor sidebar, find
   `openemr-eks-knowledge`, and enable it. If Cursor asks whether to trust the
   project MCP configuration, review the command and approve it.
4. Confirm that the server is connected and that these five tools appear:
   `get_topic`, `search_knowledge`, `read_repository_file`,
   `get_version_inventory`, and `find_operational_command`.
5. Start an Agent chat and ask:
   `Use openemr-eks-knowledge get_version_inventory for infrastructure.`

The first `uvx` start can access the network to populate its package cache.
Running `--check` first normally completes that installation before Cursor
starts the server.

### Update or remove the Cursor integration

The server reads the selected checkout dynamically, so normal documentation and
`versions.yaml` changes need no reinstall. Restart the MCP server after changing
its Python package, policy, or configured repository path.

To remove it, delete only the `openemr-eks-knowledge` entry from the selected
`mcpServers` object and refresh Cursor. Removing the configuration does not
delete the repository or uv cache.

## MCP interface

### Resources

- `knowledge://project/overview` — project purpose, major components, knowledge
  scope, and source precedence.
- `knowledge://project/architecture` — logical layers, primary data flows, and
  architecture source paths.
- `knowledge://topics/catalog` — topic slugs, aliases, summaries, and
  relationships.
- `knowledge://versions/current` — dynamic inventory parsed from
  `versions.yaml`.
- `knowledge://security/model` — project security controls and the local
  server's access boundaries.
- `knowledge://topics/{topic}` — resource template for one curated topic.

### Tools

#### `get_topic(topic)`

Returns concise curated guidance, key points, related topics, and authoritative
source paths. Accepted topic slugs are:

- `deployment`
- `architecture`
- `security`
- `monitoring`
- `backup-restore-dr`
- `credentials-rotation`
- `versions`
- `ci-cd`
- `testing`
- `troubleshooting`
- `cleanup`
- `openemr-initialization`

Common aliases such as `eks`, `auto-mode`, `backup`, `dr`, `credentials`, and
`training` are accepted.

#### `search_knowledge(query, max_results=10, context_lines=2)`

Performs case-insensitive local lexical search. Ranking favors exact phrases,
complete token matches, headings/source declarations, and path matches.

- `query`: non-empty, at most 200 characters;
- `max_results`: 1 through 20;
- `context_lines`: 0 through 5.

Results include path, match line, integer score, bounded context snippet, and
truncation metadata. Traversal, candidate ordering, and tie-breaking are
deterministic.

#### `read_repository_file(path, start_line=1, max_lines=100)`

Reads UTF-8 text from one repository-relative approved path.

- absolute paths and `..` traversal are rejected;
- `start_line` is one-based;
- `max_lines` is 1 through 250;
- individual lines are limited to 4,000 characters and returned content to
  48,000 characters;
- files larger than 512 KiB are rejected.

#### `get_version_inventory(component=None)`

Parses `versions.yaml` dynamically. The optional filter accepts a category,
component, or qualified `category.component` name. Each item includes its
category, component, current value, selected metadata, and at most 12 detected
consumer paths.

The tool does not query registries, AWS APIs, or package indexes. "Current"
means the version recorded in the local checkout.

#### `find_operational_command(task, max_results=5)`

Finds a curated command explanation and returns:

- the documented command;
- prerequisites;
- authoritative source paths;
- a risk object containing `level`, `read_only`, `destructive`,
  `cloud_affecting`, `costly`, `requires_active_context`, and
  `requires_network`.

The tool never executes the command.

## Example questions

- "Use `get_topic` to explain EKS Auto Mode architecture and cite the source
  paths."
- "Search for `credential rotation rollback` with two context lines."
- "Read lines 1–80 of `terraform/eks.tf`."
- "Show the version inventory for `monitoring`."
- "Find the project command for destroying infrastructure and explain every
  risk flag."

For operational guidance, read the returned source paths before running
anything in a separate, appropriately authorized environment.

## Security boundaries and exclusions

All paths are resolved canonically beneath the configured repository root.
Absolute paths, parent traversal, every symbolic link, and multiply linked
files are rejected. File identity and link count are checked again after
opening to prevent replacement races. Recursive search does not follow
symlinks.

Directory exclusions include:

- Git and Terraform metadata;
- virtual environments, dependency/vendor trees, and Checkov
  `.external_modules` downloads;
- Python, test, lint, type-check, and tooling caches;
- build, distribution, coverage, and test artifact directories;
- backup-output, output, report, credential, and secret directories (the
  reviewed `scripts/openemr_dr/backup/` source package remains readable);
- temporary directories.

File exclusions include:

- Terraform state and non-example `.tfvars`;
- kubeconfigs and environment files;
- private keys, certificates, keystores, and detected private-key material;
- recognized AWS credentials and GitHub, Slack, or Google API token formats,
  even when stored in an otherwise safe-named text file;
- literal password, token, and key assignments that are not recognizable
  placeholders, including quoted JSON/YAML keys;
- renamed kubeconfig files and JSON files containing private JWK material;
- credential, token, and secret files, including `k8s/secrets.yaml`;
- local logs, coverage output, and scanner reports;
- unsupported extensions, invalid UTF-8, NUL-containing/binary files, and
  oversized files.

Safe documentation that discusses credential handling remains available.
Example Terraform variable files can remain available when explicitly named as
examples.

Additional bounds protect MCP response size and work:

- repository-relative paths are limited to 4,096 characters;
- traversal examines at most 20,000 entries and skips any directory with more
  than 5,000 direct children;
- search files are limited to 256 KiB each;
- full reads are limited to 512 KiB, 250 requested lines, 4,000 characters per
  line, and 48,000 returned characters;
- `versions.yaml` rejects duplicate keys, nested response metadata, and more
  than 256 version entries;
- search queries, result counts, context, scanned files, total scanned bytes,
  snippets, and version consumer paths are capped.

The policy reduces accidental exposure from a local checkout. It is not a data
loss prevention system and should not be pointed at a repository containing
committed secrets or PHI.

## Knowledge maintenance and source precedence

The curated catalog is intentionally small. It stores summaries and source
references rather than copies of large guides.

When sources disagree, use this precedence:

1. executable source and configuration — Terraform, Kubernetes manifests,
   scripts, workflows, and package source define implemented behavior;
2. `versions.yaml` — authoritative for centrally managed current versions;
3. focused topic guides — authoritative for intent, prerequisites, and
   runbooks when consistent with implementation;
4. README overviews — useful orientation that can lag implementation.

To maintain the server:

1. update an existing topic's concise key points and source paths when
   architecture or operations change;
2. add aliases only when they do not conflict with another topic;
3. update command risk labels whenever a script's side effects or prerequisites
   change;
4. add version consumer hints only for bounded, high-signal source paths;
5. add tests for every policy or interface change;
6. do not copy secrets, generated output, or long sections of project
   documentation into the catalog.

Dynamic search and version parsing reflect the selected local checkout without
requiring a cache, vector database, or repository index.
The `--check` command also rejects missing or policy-denied curated source
references so catalog drift cannot silently pass CI.

## Development and validation

From `tools/codebase-mcp`:

```bash
uv sync --extra dev
uv run pytest
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run bandit -r src
uv run python -m build
uvx --from . openemr-eks-mcp --repo-root ../.. --check
uv run --frozen --offline openemr-eks-mcp --repo-root ../.. --check
```

Tests use temporary fixture repositories and FastMCP's in-memory
`Client(server)` transport. They require no AWS credentials, kubeconfig,
network, or live infrastructure. The configured package coverage threshold is
90%.

## Troubleshooting

### Repository root was not found

Run from the repository or pass an absolute root:

```bash
openemr-eks-mcp --repo-root /absolute/path/to/openemr-on-eks --check
```

The root must contain `versions.yaml` and expected project markers.

### A path is denied

The file may be in an excluded directory, look secret-like, be an unsupported
type, resolve through a symlink directory, contain binary/private-key material,
or exceed a size limit. Move no sensitive data merely to bypass the policy.
Use an existing safe source or focused guide instead.

### Cursor shows no tools

Run `--check` using the exact `uvx`, package, and root paths from the Cursor
configuration. Then:

1. validate the selected `mcp.json` as JSON and confirm this entry is nested
   under the single top-level `mcpServers` object with `"type": "stdio"`;
2. use the absolute `uvx` path returned by `command -v uvx`;
3. confirm `${workspaceFolder}` resolves to this project, or that every global
   repository path is absolute and still exists;
4. open Cursor's Output panel with `Cmd+Shift+U`, select **MCP Logs**, and
   inspect the initialization error;
5. refresh the server or reload the Cursor window.

Do not add an HTTP URL; this server uses STDIO. Do not redirect or print
unrelated output to stdout because stdout carries the MCP protocol.

### Cursor starts the server in other projects

The entry was probably added to `~/.cursor/mcp.json`. Move it to this
repository's `.cursor/mcp.json` when project-only scope is desired. Keep the
configured repository root absolute.

### Git installation fails

Confirm the repository URL, revision, and
`#subdirectory=tools/codebase-mcp` fragment. A Git install needs network access
once; normal server requests do not.

### Version data appears stale

The server reports the local `versions.yaml`. Update or switch the local
checkout through your normal reviewed workflow, then restart the server. The
server does not fetch newer versions.

### A command result says active context is required

The server cannot inspect that context. In a separate authorized terminal,
verify the account, region, cluster, namespace, backups, change approval, and
cost impact described by the command's source documentation before execution.
