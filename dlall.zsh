#!/bin/zsh

set -euo pipefail
setopt extended_glob null_glob

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/scripts/naming.zsh"

json_file="favorites.json"
missing_overrides_file="missing-episode-alternates.txt"
db_path="$script_dir/overcast-db/db.sqlite"
archive_root="/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"
download_user_agent="Overcast Favorites Archiver/1.0 (+https://github.com/unitof/overcast-favorites-archiver; podcast archiver)"

typeset -A fail_counts
typeset -A fail_lines
typeset -A existing_archive_keys
typeset -A override_url_by_source
typeset -A override_pending_by_source
typeset -a fail_codes
jq_alternating_filter='. as $episodes | [range(0; ($episodes | length)) as $i | (if ($i % 2) == 0 then ($i / 2 | floor) else (($episodes | length) - 1 - (($i - 1) / 2 | floor)) end) | $episodes[.]][]'
jq_name_filter='
  def output_field:
    tostring | gsub("\u001f"; " ");
  def trim_spaces: gsub("^ +| +$"; "") | gsub("  +"; " ");
  def sanitize_name:
    gsub("_"; "")
    | gsub("[^[:alnum:] .-]+"; " ")
    | trim_spaces;
  def regex_escape:
    gsub("\\."; "\\.");
  def strip_show_from_title($show):
    if $show == "" then .
    else gsub("(?i)" + ($show | regex_escape); "")
      | gsub("^[[:space:]]*[-:]+[[:space:]]*"; "")
      | gsub("[[:space:]]*[-:]+[[:space:]]*$"; "")
      | trim_spaces
    end;
  .feedTitle // "" as $feed
  | .title // "" as $title
  | ($feed | sanitize_name) as $show_name
  | ($title | sanitize_name) as $episode_title
  | ($episode_title | strip_show_from_title($show_name)) as $stripped_episode
  | [
      $feed,
      $title,
      (.userRecommendedTimeHuman // ""),
      (.episodeURL // ""),
      (.downloadURL // ""),
      (if $show_name == "" then "Unknown Show" else $show_name end),
      (if $stripped_episode != "" then $stripped_episode elif $episode_title != "" then $episode_title else "Unknown Episode" end)
    ]
  | map(output_field)
  | join("\u001f")
'
jq_episode_fields_filter="$jq_alternating_filter | $jq_name_filter"

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

index_existing_archive() {
  local existing_path
  local filename
  local base_name
  local favorite_date
  local remainder

  existing_archive_keys=()
  for existing_path in "$archive_root"/*(.N); do
    filename="${existing_path:t}"
    base_name="${filename%.*}"
    [[ "$base_name" == F????-??-??\ P????-??-??\ -\ * ]] || continue

    favorite_date="${base_name[2,11]}"
    remainder="${base_name#F????-??-?? P????-??-?? - }"
    existing_archive_keys["F${favorite_date} - ${remainder}"]=1
  done
}

load_missing_overrides() {
  local source_url
  local override_url

  override_url_by_source=()
  override_pending_by_source=()

  [[ -f "$missing_overrides_file" ]] || return

  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == \#* ]] && continue

    source_url="${entry%%[[:space:]]##*}"
    override_url="${entry#"$source_url"}"
    override_url="${override_url##[[:space:]]##}"

    [[ -z "$source_url" ]] && continue
    if [[ -z "$override_url" || "$source_url" == "$override_url" ]]; then
      override_pending_by_source[$source_url]=1
      continue
    fi
    override_url_by_source[$source_url]="$override_url"
  done < "$missing_overrides_file"
}

download_with_yt_dlp() {
  local source_url="$1"
  local out_path_base="$2"
  local out_path_ref_name="$3"
  local temp_template="${out_path_base}.%(ext)s"
  local produced_path

  if ! command -v yt-dlp >/dev/null 2>&1; then
    record_failure "yt-dlp-missing" "${feedTitle} - ${title} (${source_url})"
    echo "Failed (yt-dlp missing) $title"
    return 1
  fi

  echo "Downloading Alternate $title -> ${out_path_base}.mp3 (yt-dlp: $source_url)"

  if ! yt-dlp \
    --quiet \
    --no-warnings \
    --extract-audio \
    --audio-format mp3 \
    --audio-quality 0 \
    --output "$temp_template" \
    "$source_url"; then
    rm -f "${out_path_base}".*
    record_failure "yt-dlp" "${feedTitle} - ${title} (${source_url})"
    echo "Failed (yt-dlp) $title"
    return 1
  fi

  produced_path="${out_path_base}.mp3"
  if [[ ! -f "$produced_path" ]]; then
    record_failure "yt-dlp" "${feedTitle} - ${title} (${source_url})"
    echo "Failed (yt-dlp) $title"
    return 1
  fi

  typeset -g "$out_path_ref_name=$produced_path"
  return 0
}

field_separator=$'\x1f'
oc_init_published_lookup "$db_path"
index_existing_archive
load_missing_overrides
if [[ -n "$oc_published_lookup_warning" ]]; then
  echo "Warning: $oc_published_lookup_warning"
fi

while IFS="$field_separator" read -r feedTitle title episodeDate episodeURL url show_name episode_name; do
  override_url="${override_url_by_source[$url]:-}"
  override_pending="${override_pending_by_source[$url]:-}"

  skip_key="F${episodeDate} - ${show_name} - ${episode_name}"
  if (( ${+existing_archive_keys[$skip_key]} )); then
    echo "Skipping $title (already exists)"
    continue
  fi

  # Fallback for files that don't match the canonical naming pattern.
  show_name_glob="${(b)show_name}"
  episode_name_glob="${(b)episode_name}"
  existing_matches=(
    "$archive_root"/F${episodeDate}\ P????-??-??\ -\ ${show_name_glob}\ -\ ${episode_name_glob}.*
  )
  if (( ${#existing_matches[@]} > 0 )); then
    existing_archive_keys[$skip_key]=1
    echo "Skipping $title (already exists)"
    continue
  fi

  # Only build the canonical name when we actually need to download.
  published_date=$(oc_get_published_date "$episodeURL" "$url")
  if [[ -z "$published_date" ]]; then
    published_date="$episodeDate"
    ((oc_published_missing++))
  fi
  out_path_base="$archive_root/F${episodeDate} P${published_date} - ${show_name} - ${episode_name}"

  if [[ -n "$override_url" && "$override_url" == (#i)(https://)(www.|m.)#(youtube.com|youtu.be)(/*|) ]]; then
    if download_with_yt_dlp "$override_url" "$out_path_base" out_path; then
      existing_archive_keys[$skip_key]=1
    fi
    continue
  fi

  if [[ -n "$override_url" ]]; then
    url="$override_url"
  fi

  # 1) HEAD request to get final URL after redirects
  final_url=$(curl -sIL -A "$download_user_agent" -w '%{url_effective}' -o /dev/null --max-redirs 20 "$url")

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

  download_label="Downloading $url -> $out_path (final URL: $final_url)"
  if [[ -n "$override_url" ]]; then
    download_label="Downloading Alternate $title -> $out_path (URL: $override_url, final URL: $final_url)"
  elif [[ -n "$override_pending" ]]; then
    download_label="Downloading Original $title -> $out_path (no rewrite specified)"
  fi
  echo "$download_label"

  # 3) Actually download using the original URL (curl -L follows redirects)
  http_code=$(curl -L --max-redirs 20 --retry 3 --silent --show-error \
    -A "$download_user_agent" \
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

  existing_archive_keys[$skip_key]=1
done < <(jq -r "$jq_episode_fields_filter" "$json_file") || true

if (( oc_published_missing > 0 )); then
  echo ""
  echo "Missing published dates for ${oc_published_missing} episode(s); used favorited dates."
fi

if (( ${#fail_codes[@]} > 0 )); then
  echo ""
  echo "Failed downloads by HTTP code or source:"
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
