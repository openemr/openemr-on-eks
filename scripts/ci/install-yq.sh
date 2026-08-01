#!/usr/bin/env bash
# Install yq for reading versions.yaml (CI and local dev).
set -euo pipefail

if command -v yq >/dev/null 2>&1; then
  echo "yq already installed: $(yq --version 2>/dev/null || yq -V 2>/dev/null || echo ok)"
  exit 0
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
esac

YQ_VERSION="${YQ_VERSION:-v4.53.3}"
URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
TARGET="/usr/local/bin/yq"

if [[ -w "$(dirname "${TARGET}")" ]]; then
  curl -fsSL "${URL}" -o "${TARGET}"
  chmod +x "${TARGET}"
else
  sudo curl -fsSL "${URL}" -o "${TARGET}"
  sudo chmod +x "${TARGET}"
fi

yq --version
