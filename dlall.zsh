#!/bin/zsh

json_file="favorites.json"

jq -c '.[]' "$json_file" | while read -r episode; do
  feedTitle=$(echo "$episode" | jq -r '.feedTitle' | tr -d '_')
  title=$(echo "$episode" | jq -r '.title'     | tr -cs '[:alnum:] _.-' '_')
  url=$(echo "$episode" | jq -r '.downloadURL')

  # First, construct a preliminary output path to check if file exists
  # Use mp3 as default extension for initial check
  out_path_base="/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]/$feedTitle - $title"
  
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
  curl -L --max-redirs 20 --fail --retry 3 --silent --show-error "$url" -o "$out_path"
done