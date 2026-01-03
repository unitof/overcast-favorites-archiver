#!/bin/zsh
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Install with: brew install jq"
  exit 1
fi

zsh ./dlall.zsh
