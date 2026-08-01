# OpenEMR EKS Knowledge MCP

A strictly read-only, local FastMCP server for curated OpenEMR on EKS repository
knowledge and bounded lexical source inspection.

Requires Python 3.11+ and
[uv](https://docs.astral.sh/uv/getting-started/installation/).

From the repository root, validate the package:

```bash
uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root . --check
```

The server uses STDIO by default. It does not execute commands, contact networks or
cloud services, invoke Git, or write files during normal operation.

For Cursor, add `openemr-eks-knowledge` to either the project
`.cursor/mcp.json` or user `~/.cursor/mcp.json` and run this package with
`"type": "stdio"`. Use an absolute `uvx` path; project configuration can use
`${workspaceFolder}` for the package and repository paths. See
[`../../docs/KNOWLEDGE_MCP.md`](../../docs/KNOWLEDGE_MCP.md) for the
copy-paste configuration, verification steps, interface, security boundaries,
and development instructions.
