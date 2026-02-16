#!/bin/zsh
set -euo pipefail

setopt extended_glob

oc_published_lookup_enabled=0
oc_published_db_path=""
oc_published_lookup_warning=""
typeset -A oc_published_cache
oc_published_missing=0

oc_escape_sed() {
  printf '%s' "$1" | sed -e 's/[][\\/.*^$|(){}+?]/\\&/g'
}

oc_sanitize_name() {
  local raw="$1"
  raw="${raw//_/}"
  raw=$(echo "$raw" | tr -cs '[:alnum:] .-' ' ')
  raw=$(echo "$raw" | sed 's/^ *//; s/ *$//; s/  */ /g')
  echo "$raw"
}

oc_strip_show_from_title() {
  local title="$1"
  local show="$2"
  if [[ -z "$show" ]]; then
    echo "$title"
    return
  fi
  local show_esc
  show_esc=$(oc_escape_sed "$show")
  local stripped
  stripped=$(printf '%s' "$title" | sed -E "s/${show_esc}//Ig")
  stripped=$(printf '%s' "$stripped" | sed -E 's/^[[:space:]]*[-:]+[[:space:]]*//; s/[[:space:]]*[-:]+[[:space:]]*$//')
  stripped=$(printf '%s' "$stripped" | sed 's/^ *//; s/ *$//; s/  */ /g')
  echo "$stripped"
}

oc_init_published_lookup() {
  local db_path="$1"
  oc_published_cache=()
  oc_published_missing=0
  oc_published_lookup_warning=""
  if [[ -n "$db_path" && -f "$db_path" ]]; then
    if command -v sqlite-utils >/dev/null 2>&1; then
      oc_published_lookup_enabled=1
      oc_published_db_path="$db_path"
    else
      oc_published_lookup_enabled=0
      oc_published_lookup_warning="sqlite-utils not found; using favorited dates for published dates"
    fi
  else
    oc_published_lookup_enabled=0
    oc_published_lookup_warning="Overcast DB not found; using favorited dates for published dates"
  fi
}

oc_get_published_date() {
  local episode_url="$1"
  local download_url="$2"
  local cache_key="${episode_url}|${download_url}"
  if (( ${+oc_published_cache[$cache_key]} )); then
    echo "${oc_published_cache[$cache_key]}"
    return
  fi

  local published=""
  if (( oc_published_lookup_enabled )); then
    published=$(sqlite-utils query "$oc_published_db_path" \
      "select STRFTIME('%Y-%m-%d', CAST(publishedTime as float),'unixepoch') as publishedDate from OCEpisode where linkURL = :episodeURL or enclosureURL = :downloadURL order by publishedTime desc limit 1" \
      -p episodeURL "$episode_url" -p downloadURL "$download_url" \
      | jq -r '.[0].publishedDate // empty')
    if [[ "$published" == "1970-01-01" ]]; then
      published=""
    fi
  fi

  oc_published_cache[$cache_key]="$published"
  echo "$published"
}

oc_build_base_name() {
  local feed_title_raw="$1"
  local title_raw="$2"
  local favorite_date="$3"
  local episode_url="$4"
  local download_url="$5"

  local show_name
  local episode_title
  local episode_name

  show_name=$(oc_sanitize_name "$feed_title_raw")
  episode_title=$(oc_sanitize_name "$title_raw")
  episode_name=$(oc_strip_show_from_title "$episode_title" "$show_name")

  if [[ -z "$show_name" ]]; then
    show_name="Unknown Show"
  fi
  if [[ -z "$episode_name" ]]; then
    episode_name="$episode_title"
  fi
  if [[ -z "$episode_name" ]]; then
    episode_name="Unknown Episode"
  fi

  local published_date
  published_date=$(oc_get_published_date "$episode_url" "$download_url")
  if [[ -z "$published_date" ]]; then
    published_date="$favorite_date"
    ((oc_published_missing++))
  fi

  echo "F${favorite_date} P${published_date} - ${show_name} - ${episode_name}"
}

oc_legacy_base_name() {
  local feed_title_raw="$1"
  local title_raw="$2"
  local favorite_date="$3"

  local feed_title
  local title

  feed_title=$(oc_sanitize_name "$feed_title_raw")
  title=$(oc_sanitize_name "$title_raw")

  if [[ -z "$feed_title" ]]; then
    feed_title="Unknown Show"
  fi
  if [[ -z "$title" ]]; then
    title="Unknown Episode"
  fi

  echo "${feed_title} - ${favorite_date} - ${title}"
}
