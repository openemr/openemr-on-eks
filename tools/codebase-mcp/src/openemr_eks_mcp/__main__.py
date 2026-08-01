"""Allow ``python -m openemr_eks_mcp`` execution."""

from openemr_eks_mcp.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
