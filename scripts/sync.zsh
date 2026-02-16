#!/bin/zsh
set -euo pipefail

if ! command -v sqlite-utils >/dev/null 2>&1; then
  echo "sqlite-utils not found. Install with: brew install sqlite-utils"
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
bundle_id="fm.overcast.overcast"
containers_dir="$HOME/Library/Containers"
src_dir="$(
  for container in "$containers_dir"/*; do
    metadata_plist="$container/.com.apple.containermanagerd.metadata.plist"
    [[ -f "$metadata_plist" ]] || continue
    metadata_id="$(plutil -extract MCMMetadataIdentifier raw -o - "$metadata_plist" 2>/dev/null || true)"
    [[ "$metadata_id" == "$bundle_id" ]] || continue

    data_dir="$container/Data/Documents"
    db_path="$data_dir/db.sqlite"
    [[ -f "$db_path" ]] || continue

    printf "%s\t%s\n" "$(stat -f '%m' "$db_path")" "$data_dir"
  done | sort -nr | head -n1 | cut -f2-
)"
if [[ -z "${src_dir}" ]]; then
  echo "Could not locate Overcast DB container for bundle ID: $bundle_id"
  echo "Open Overcast.app once, then retry."
  exit 1
fi

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
