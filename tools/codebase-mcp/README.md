# OpenEMR EKS Knowledge MCP

A strictly read-only, local FastMCP server for curated OpenEMR on EKS repository
knowledge and bounded lexical source inspection.

From the repository root:

```bash
uvx --from ./tools/codebase-mcp openemr-eks-mcp --repo-root .
```

The server uses STDIO by default. It does not execute commands, contact networks or
cloud services, invoke Git, or write files during normal operation.

See `docs/KNOWLEDGE_MCP.md` in the repository for configuration, interface,
security boundaries, and development instructions.
