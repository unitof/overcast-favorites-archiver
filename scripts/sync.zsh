#!/bin/zsh
set -euo pipefail

if ! command -v sqlite-utils >/dev/null 2>&1; then
  echo "sqlite-utils not found. Install with: brew install sqlite-utils"
  exit 1
fi

sqlite-utils ~/Library/Containers/2EFFC350-6DCA-4E17-9FCC-4BBBC7C484C0/Data/Documents/db.sqlite "$(<./scripts/overcast_export_recommended_episodes.sql)" > favorites.json
