#!/bin/zsh

set -euo pipefail
setopt extended_glob null_glob

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/scripts/naming.zsh"

json_file="favorites.json"
db_path="$script_dir/overcast-db/db.sqlite"
archive_root="/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"

typeset -A fail_counts
typeset -A fail_lines
typeset -a fail_codes

record_failure() {
  local code="$1"
  local line="$2"

  if [[ -z "${fail_counts[$code]:-}" ]]; then
    fail_counts[$code]=0
    fail_codes+=("$code")
    fail_lines[$code]=""
  fi

  ((fail_counts[$code]++))
  fail_lines[$code]+="${line}"$'\n'
}

oc_init_published_lookup "$db_path"
if [[ -n "$oc_published_lookup_warning" ]]; then
  echo "Warning: $oc_published_lookup_warning"
fi

while read -r episode; do
  feedTitle=$(echo "$episode" | jq -r '.feedTitle')
  title=$(echo "$episode" | jq -r '.title')
  episodeDate=$(echo "$episode" | jq -r '.userRecommendedTimeHuman')
  episodeURL=$(echo "$episode" | jq -r '.episodeURL')
  url=$(echo "$episode" | jq -r '.downloadURL')

  # First, construct a preliminary output path to check if file exists
  # Use mp3 as default extension for initial check
  out_path_base="$archive_root/$(oc_build_base_name "$feedTitle" "$title" "$episodeDate" "$episodeURL" "$url")"
  
  # Check if any file with this base name already exists (with any extension)
  if ls "$out_path_base".* >/dev/null 2>&1; then
    echo "Skipping $title (already exists)"
    continue
  fi

  # 1) HEAD request to get final URL after redirects
  final_url=$(curl -sIL -w '%{url_effective}' -o /dev/null --max-redirs 20 "$url")

  # 2) Parse final URL to extract a filename and extension
  final_filename=$(basename "$final_url")
  # Remove query strings, etc.
  final_filename=$(echo "$final_filename" | sed 's/[?#].*$//')

  ext="${final_filename##*.}"
  if [ "$ext" = "$final_filename" ]; then
    # If there was no dot, fallback to mp3
    ext="mp3"
  fi

  # Construct final output path
  out_path="$out_path_base.$ext"
  mkdir -p "$(dirname "$out_path")"

  echo "Downloading $url -> $out_path (final URL: $final_url)"

  # 3) Actually download using the original URL (curl -L follows redirects)
  http_code=$(curl -L --max-redirs 20 --retry 3 --silent --show-error \
    --write-out '%{http_code}' \
    --output "$out_path" \
    "$url")
  curl_exit=$?

  if (( curl_exit != 0 )); then
    rm -f "$out_path"
    [[ -z "$http_code" ]] && http_code="000"
    record_failure "$http_code" "$feedTitle - $title ($url)"
    echo "Failed ($http_code) $title"
    continue
  fi

  if [[ "$http_code" -ge 400 ]]; then
    rm -f "$out_path"
    record_failure "$http_code" "$feedTitle - $title ($url)"
    echo "Failed ($http_code) $title"
    continue
  fi
done < <(jq -c '.[]' "$json_file") || true

if (( oc_published_missing > 0 )); then
  echo ""
  echo "Missing published dates for ${oc_published_missing} episode(s); used favorited dates."
fi

if (( ${#fail_codes[@]} > 0 )); then
  echo ""
  echo "Failed downloads by HTTP code:"
  for code in "${fail_codes[@]}"; do
    echo "  $code (${fail_counts[$code]})"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "    - $line"
    done <<< "${fail_lines[$code]}"
  done
else
  echo "All downloads succeeded."
fi
