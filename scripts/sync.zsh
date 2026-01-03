#!/bin/zsh
set -euo pipefail

if ! command -v sqlite-utils >/dev/null 2>&1; then
  echo "sqlite-utils not found. Install with: brew install sqlite-utils"
  exit 1
fi

src_dir="$HOME/Library/Containers/2EFFC350-6DCA-4E17-9FCC-4BBBC7C484C0/Data/Documents"
tmp_dir="$(mktemp -d "./.overcast-sync.XXXXXX")"
tmp_db="$tmp_dir/db.sqlite"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cp "$src_dir/db.sqlite" "$tmp_db"
if [[ -f "$src_dir/db.sqlite-wal" ]]; then
  cp "$src_dir/db.sqlite-wal" "$tmp_dir/db.sqlite-wal"
fi
if [[ -f "$src_dir/db.sqlite-shm" ]]; then
  cp "$src_dir/db.sqlite-shm" "$tmp_dir/db.sqlite-shm"
fi

sqlite-utils "$tmp_db" "$(<./scripts/overcast_export_recommended_episodes.sql)" > favorites.json
