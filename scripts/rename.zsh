#!/bin/zsh
set -euo pipefail
setopt extended_glob null_glob

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Install with: brew install jq"
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/naming.zsh"

json_file="$repo_root/favorites.json"
db_path="$repo_root/overcast-db/db.sqlite"
archive_root="/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"

if [[ ! -f "$json_file" ]]; then
  echo "favorites.json not found at $json_file"
  exit 1
fi

oc_init_published_lookup "$db_path"
if [[ -n "$oc_published_lookup_warning" ]]; then
  echo "Warning: $oc_published_lookup_warning"
fi

renamed=0
missing=0
collisions=0
already=0

while read -r episode; do
  feedTitle=$(echo "$episode" | jq -r '.feedTitle')
  title=$(echo "$episode" | jq -r '.title')
  favoriteDate=$(echo "$episode" | jq -r '.userRecommendedTimeHuman')
  episodeURL=$(echo "$episode" | jq -r '.episodeURL')
  downloadURL=$(echo "$episode" | jq -r '.downloadURL')

  old_base_name=$(oc_legacy_base_name "$feedTitle" "$title" "$favoriteDate")
  old_base="$archive_root/$old_base_name"
  new_base_name=$(oc_build_base_name "$feedTitle" "$title" "$favoriteDate" "$episodeURL" "$downloadURL")
  new_base="$archive_root/$new_base_name"

  existing_new=("$new_base".*(N))
  if (( ${#existing_new[@]} > 0 )); then
    ((already++))
    continue
  fi

  matches=("$old_base".*(N))
  if (( ${#matches[@]} == 0 )); then
    ((missing++))
    continue
  fi

  for file in "${matches[@]}"; do
    ext="${file#$old_base.}"
    target="${new_base}.${ext}"
    if [[ -e "$target" ]]; then
      ((collisions++))
      continue
    fi
    /bin/mv "$file" "$target"
    ((renamed++))
  done

done < <(jq -c '.[]' "$json_file") || true

if (( oc_published_missing > 0 )); then
  echo "Missing published dates for ${oc_published_missing} episode(s); used favorited dates."
fi

echo "Renamed: $renamed"
echo "Already renamed: $already"
echo "Missing originals: $missing"
echo "Collisions skipped: $collisions"
