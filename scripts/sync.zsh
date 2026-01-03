#!/bin/zsh
set -euo pipefail

if ! command -v sqlite-utils >/dev/null 2>&1; then
  echo "sqlite-utils not found. Install with: brew install sqlite-utils"
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
src_dir="$HOME/Library/Containers/2EFFC350-6DCA-4E17-9FCC-4BBBC7C484C0/Data/Documents"
dest_dir="$repo_root/overcast-db"
dest_db="$dest_dir/db.sqlite"

mkdir -p "$dest_dir"

cp "$src_dir/db.sqlite" "$dest_db"
if [[ -f "$src_dir/db.sqlite-wal" ]]; then
  cp "$src_dir/db.sqlite-wal" "$dest_dir/db.sqlite-wal"
fi
if [[ -f "$src_dir/db.sqlite-shm" ]]; then
  cp "$src_dir/db.sqlite-shm" "$dest_dir/db.sqlite-shm"
fi

sqlite-utils "$dest_db" "$(<./scripts/overcast_export_recommended_episodes.sql)" > favorites.json
