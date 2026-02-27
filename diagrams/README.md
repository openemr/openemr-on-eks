# Architecture Diagrams

Architecture diagrams generated directly from the Terraform source code using [Terravision](https://github.com/patrickchugh/terravision).

## Table of Contents

<img src="../images/diagrams_table_of_contents_section_picture.png" alt="Diagrams table of contents section picture" width="300">

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [How to Generate](#how-to-generate)
- [File Listing](#file-listing)
- [Design Decisions](#design-decisions)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
cd diagrams
./generate.sh
# Output: diagrams/architecture.png
```

## Prerequisites

| Tool | Install Command | Purpose |
|------|----------------|---------|
| **Terravision** | `pip install terravision` (or `pipx install terravision`) | Reads Terraform HCL and generates architecture diagrams |
| **Graphviz** | `brew install graphviz` (macOS) / `sudo apt-get install -y graphviz` (Linux) | Graph layout engine used by Terravision |
| **Terraform 1.x** | `brew install terraform` (or `tfenv install`) | Required by Terravision to run `terraform plan` |
| **AWS Credentials** | `aws configure` or `aws sso login` | Terraform needs valid credentials to plan against AWS APIs |

## How to Generate

1. **Install dependencies** (one-time setup):

   ```bash
   pip install terravision
   brew install graphviz terraform   # macOS
   ```

2. **Ensure AWS credentials are active**:

   ```bash
   aws sts get-caller-identity   # should return your account/role
   ```

3. **Generate the diagram**:

   ```bash
   cd diagrams
   ./generate.sh
   ```

4. The output file `architecture.png` is created (or overwritten) in the `diagrams/` directory.

### CI/CD Usage

Terravision supports a **pre-generated plan** workflow so the diagram step does not need AWS credentials:

```bash
# Step 1 — in the Terraform environment (has credentials)
cd terraform
terraform init
terraform plan -out=tfplan.bin
terraform show -json tfplan.bin > plan.json
terraform graph > graph.dot

# Step 2 — in the diagram step (no credentials needed)
terravision draw --planfile plan.json --graphfile graph.dot --source ./terraform
```

See the [Terravision CI/CD docs](https://github.com/patrickchugh/terravision/blob/main/docs/CICD_INTEGRATION.md) for GitHub Actions, GitLab CI, and Jenkins examples.

## File Listing

| File | Description |
|------|-------------|
| `generate.sh` | Shell script that wraps Terravision with preflight checks and path handling |
| `architecture.png` | Generated architecture diagram (committed to the repo for README display) |
| `README.md` | This file |

## Design Decisions

### Why Terravision?

| Concern | Terravision | Manual / hand-coded diagrams |
|---------|-------------|------------------------------|
| **Source of truth** | Generated from actual Terraform code | Drifts from reality over time |
| **Accuracy** | Reads `terraform plan` — shows exactly what would be created | Depends on author's memory |
| **AWS icons** | Official AWS Architecture Icon set | Varies by tool |
| **Output formats** | PNG, SVG, PDF, draw.io, and more | Depends on tool |
| **CI/CD ready** | Pre-generated plan mode skips credentials in the diagram step | Not automatable |
| **Version control** | Re-run script after Terraform changes; diff the PNG | Binary blob with no provenance |

### Alternatives Considered

| Tool | Why Not Used |
|------|-------------|
| **inframap** (cycloidio) | Produces very sparse output from HCL — only showed 2 resources for this project |
| **Rover** | Interactive visualizer; requires running state, no static export |
| **Pluralith** | Requires Terraform state/plan files and a Pluralith account |
| **Python `diagrams` library** | Hand-coded — does not read Terraform; diagram drifts from infrastructure |

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| `command not found: terravision` | Not installed | `pip install terravision` (or `pipx install terravision`) |
| `command not found: dot` | Graphviz not installed | `brew install graphviz` (macOS) or `sudo apt-get install -y graphviz` |
| `ERROR: AWS credentials are not configured` | No active AWS session | Run `aws configure`, `aws sso login`, or export `AWS_PROFILE` |
| `ERROR: Invalid output from 'terraform plan'` | Terraform can't plan (missing provider, bad config) | Run `terraform plan` manually in `terraform/` to debug |
| Output is `architecture.dot.png` instead of `architecture.png` | Terravision naming convention | `generate.sh` handles this rename automatically |
| Diagram looks different after Terraform changes | Expected — diagram reflects current code | Commit the updated `architecture.png` |
