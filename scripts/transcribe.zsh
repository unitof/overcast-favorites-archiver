#!/bin/zsh
set -euo pipefail
setopt extended_glob null_glob

local_yap_root="${YAP_LOCAL_ROOT:-$HOME/repos/forks/yap}"
local_yap_candidates=(
  "$local_yap_root/.build/arm64-apple-macosx/release/yap"
  "$local_yap_root/.build/arm64-apple-macosx/debug/yap"
  "$local_yap_root/.build/release/yap"
  "$local_yap_root/.build/debug/yap"
)

yap_path=""
if [[ -n "${YAP_PATH:-}" ]]; then
  yap_path="$YAP_PATH"
else
  for candidate in "${local_yap_candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      yap_path="$candidate"
      break
    fi
  done
fi

if [[ -z "$yap_path" || ! -x "$yap_path" ]]; then
  yap_path="$(command -v yap 2>/dev/null || true)"
fi

if [[ -z "$yap_path" || ! -x "$yap_path" ]]; then
  echo "yap not found. Install with: brew install finnvoor/tools/yap"
  exit 1
fi

usage() {
  cat <<'USAGE'
Usage: scripts/transcribe.zsh [options] [paths...]

Options:
  -r, --recursive       Recurse into subdirectories when scanning folders.
  --extensions LIST     Comma-separated list of audio extensions to include.
  --format FORMAT       Sidecar format to emit: txt or srt (default: srt).
  --txt                 Shortcut for --format txt.
  --srt                 Shortcut for --format srt.
  --overwrite           Overwrite existing sidecar files instead of skipping.
  --locale LOCALE       Locale for transcription (passed to yap).
  --max-length N        Max line length for yap output (default: 1000000).
  --censor              Enable audio censoring (passed to yap).
  -h, --help            Show this help message.

If no paths are provided, the Overcast Favorites archive path is used.
SRT output is post-processed to remove index lines and saved as .srt.txt.
USAGE
}

default_paths=(
  "/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"
)

audio_extensions_default=".aac,.flac,.m4a,.m4b,.mkv,.mov,.mp3,.mp4,.ogg,.opus,.wav"

recursive=0
overwrite=0
format="srt"
extensions_string="$audio_extensions_default"
locale="" # should default to current
censor=0
max_length="1000000"

paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--recursive)
      recursive=1
      shift
      ;;
    --overwrite)
      overwrite=1
      shift
      ;;
    --txt)
      format="txt"
      shift
      ;;
    --srt)
      format="srt"
      shift
      ;;
    --format)
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#*=}"
      shift
      ;;
    --extensions)
      extensions_string="$2"
      shift 2
      ;;
    --extensions=*)
      extensions_string="${1#*=}"
      shift
      ;;
    --locale)
      locale="$2"
      shift 2
      ;;
    --locale=*)
      locale="${1#*=}"
      shift
      ;;
    --max-length)
      max_length="$2"
      shift 2
      ;;
    --max-length=*)
      max_length="${1#*=}"
      shift
      ;;
    --censor)
      censor=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        paths+=("$1")
        shift
      done
      ;;
    -* )
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

if (( ${#paths[@]} == 0 )); then
  paths=("${default_paths[@]}")
fi

if [[ -z "$locale" ]]; then
  raw_locale=""
  for candidate in "${LC_ALL:-}" "${LANG:-}" "${LC_CTYPE:-}"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    base="${candidate%%.*}"
    base="${base%%@*}"
    if [[ "$base" != "C" && "$base" != "POSIX" ]]; then
      raw_locale="$base"
      break
    fi
  done
  if [[ -n "$raw_locale" ]]; then
    locale="${raw_locale//_/-}"
  fi
fi

IFS=',' read -r -A ext_list <<< "$extensions_string"
extensions=()
for ext in "${ext_list[@]}"; do
  ext="${ext:l}"
  if [[ -z "$ext" ]]; then
    continue
  fi
  if [[ "$ext" != .* ]]; then
    ext=".$ext"
  fi
  extensions+=("$ext")
done
unset IFS

is_audio() {
  local file="$1"
  local ext=".${file##*.}"
  ext="${ext:l}"
  for allowed in "${extensions[@]}"; do
    if [[ "$ext" == "${allowed:l}" ]]; then
      return 0
    fi
  done
  return 1
}

extract_episode_date() {
  local path="$1"
  local base="${path:t:r}"
  local date=""

  if [[ "$base" == F????-??-??\ P????-??-??\ -* ]]; then
    date="${base[2,11]}"
  elif [[ "$base" == F????-??-??\ -* ]]; then
    date="${base[2,11]}"
  elif [[ "$base" == *" - "????-??-??" - "* ]]; then
    local tail="${base#* - }"
    date="${tail%% - *}"
  fi

  if [[ "$date" == ????-??-?? ]]; then
    printf '%s\n' "$date"
  fi
}

reorder_newest_oldest_alternating() {
  local -a input=("$@")
  local -a dated_records=()
  local -a undated=()
  local -a dated_sorted=()
  local -a dated_paths=()
  local -a reordered=()
  local audio_path date left right

  for audio_path in "${input[@]}"; do
    date="$(extract_episode_date "$audio_path")"
    if [[ -n "$date" ]]; then
      dated_records+=("${date}"$'\t'"$audio_path")
    else
      undated+=("$audio_path")
    fi
  done

  if (( ${#dated_records[@]} > 0 )); then
    dated_sorted=("${(@f)$(printf '%s\n' "${dated_records[@]}" | LC_ALL=C sort -r)}")
    for record in "${dated_sorted[@]}"; do
      dated_paths+=("${record#*$'\t'}")
    done

    left=1
    right=${#dated_paths[@]}
    while (( left <= right )); do
      reordered+=("${dated_paths[$left]}")
      ((left++))
      if (( left <= right )); then
        reordered+=("${dated_paths[$right]}")
        ((right--))
      fi
    done
  fi

  reordered+=("${undated[@]}")
  printf '%s\n' "${reordered[@]}"
}

audio_files=()
for scan_path in "${paths[@]}"; do
  if [[ -f "$scan_path" ]]; then
    if is_audio "$scan_path"; then
      audio_files+=("$scan_path")
    fi
    continue
  fi
  if [[ -d "$scan_path" ]]; then
    if (( recursive )); then
      for file in "$scan_path"/**/*(.N); do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done
    else
      for file in "$scan_path"/*(.N); do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done
    fi
    continue
  fi
  echo "Path not found: $scan_path"
done

if (( ${#audio_files[@]} == 0 )); then
  echo "No audio files found."
  exit 1
fi

typeset -U audio_files

case "$format" in
  txt|srt)
    ;;
  *)
    echo "Unsupported format: $format (use txt or srt)."
    exit 1
    ;;
 esac

audio_files=("${(@f)$(reorder_newest_oldest_alternating "${audio_files[@]}")}")

pending_audio_files=()
skipped_sidecar_count=0
for audio_path in "${audio_files[@]}"; do
  output_base="${audio_path%.*}"
  if [[ "$format" == "srt" ]]; then
    output_path="${output_base}.srt.txt"
  else
    output_path="${output_base}.${format}"
  fi
  if [[ -e "$output_path" && $overwrite -eq 0 ]]; then
    ((++skipped_sidecar_count))
    continue
  fi
  pending_audio_files+=("$audio_path")
done
audio_files=("${pending_audio_files[@]}")

if (( skipped_sidecar_count > 0 && overwrite == 0 )); then
  echo "Skipping ${skipped_sidecar_count} file(s) with existing sidecar."
fi

if (( ${#audio_files[@]} == 0 )); then
  echo "No audio files need transcription."
  exit 0
fi

failures=()

for audio_path in "${audio_files[@]}"; do
  output_base="${audio_path%.*}"
  if [[ "$format" == "srt" ]]; then
    output_path="${output_base}.srt.txt"
    temp_output_path="${output_base}.srt"
  else
    output_path="${output_base}.${format}"
    temp_output_path=""
  fi

  echo "Transcribing $audio_path"
  if [[ "$format" == "srt" ]]; then
    cmd=("$yap_path" transcribe "$audio_path" -o "$temp_output_path")
  else
    cmd=("$yap_path" transcribe "$audio_path" -o "$output_path")
  fi
  if [[ "$format" == "srt" ]]; then
    cmd+=(--srt)
  else
    cmd+=(--txt)
  fi
  if [[ -n "$max_length" ]]; then
    cmd+=(--max-length "$max_length")
  fi
  if [[ -n "$locale" ]]; then
    cmd+=(--locale "$locale")
  fi
  if (( censor )); then
    cmd+=(--censor)
  fi

  set +e
  "${cmd[@]}"
  exit_status=$?
  set -e

  if (( exit_status == 0 )); then
    if [[ "$format" == "srt" ]]; then
      filtered_path="${temp_output_path}.filtered"
      set +e
      /usr/bin/awk '
        function is_index(line) { return line ~ /^[0-9]+$/ }
        function is_ts(line) { return line ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> / }
        function emit(line) {
          if (is_ts(line) && emitted && !last_blank) {
            print ""
          }
          print line
          emitted=1
          last_blank = (line == "")
        }
        {
          if (has_pending) {
            if (is_index(pending) && is_ts($0)) {
              # drop the SRT index line
            } else {
              emit(pending)
            }
          }
          pending=$0
          has_pending=1
        }
        END {
          if (has_pending) {
            emit(pending)
          }
        }
      ' "$temp_output_path" > "$filtered_path"
      awk_status=$?
      post_status=$awk_status
      if (( awk_status == 0 )); then
        /bin/mv "$filtered_path" "$temp_output_path"
        post_status=$?
        if (( post_status == 0 )); then
          /bin/mv "$temp_output_path" "$output_path"
          post_status=$?
        fi
      fi
      set -e
      if (( post_status == 0 )); then
        echo "Wrote $output_path"
      else
        echo "Post-processing failed for $audio_path; skipping"
        failures+=("$audio_path")
      fi
    else
      echo "Wrote $output_path"
    fi
  else
    echo "yap failed for $audio_path (exit $exit_status); skipping"
    failures+=("$audio_path")
  fi
done

if (( ${#failures[@]} > 0 )); then
  echo ""
  echo "Transcription failures (${#failures[@]}):"
  for failed in "${failures[@]}"; do
    echo "  - $failed"
  done
  exit 1
fi
