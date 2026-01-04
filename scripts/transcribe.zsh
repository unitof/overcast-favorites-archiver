#!/bin/zsh
set -euo pipefail

if ! command -v yap >/dev/null 2>&1; then
  echo "yap not found. Install with: brew install finnvoor/tools/yap"
  exit 1
fi

usage() {
  cat <<'USAGE'
Usage: scripts/transcribe.zsh [options] [paths...]

Options:
  -r, --recursive       Recurse into subdirectories when scanning folders.
  --extensions LIST     Comma-separated list of audio extensions to include.
  --format FORMAT       Sidecar format to emit: txt or srt (default: txt).
  --txt                 Shortcut for --format txt.
  --srt                 Shortcut for --format srt.
  --overwrite           Overwrite existing sidecar files instead of skipping.
  --locale LOCALE       Locale for transcription (passed to yap).
  --censor              Enable audio censoring (passed to yap).
  -h, --help            Show this help message.

If no paths are provided, the Overcast Favorites archive path is used.
USAGE
}

default_paths=(
  "/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"
)

audio_extensions_default=".aac,.flac,.m4a,.m4b,.mkv,.mov,.mp3,.mp4,.ogg,.opus,.wav"

recursive=0
overwrite=0
format="txt"
extensions_string="$audio_extensions_default"
locale=""
censor=0

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

audio_files=()
for path in "${paths[@]}"; do
  if [[ -f "$path" ]]; then
    if is_audio "$path"; then
      audio_files+=("$path")
    fi
    continue
  fi
  if [[ -d "$path" ]]; then
    if (( recursive )); then
      while IFS= read -r -d '' file; do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done < <(find "$path" -type f -print0)
    else
      while IFS= read -r -d '' file; do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done < <(find "$path" -maxdepth 1 -type f -print0)
    fi
    continue
  fi
  echo "Path not found: $path"
done

if (( ${#audio_files[@]} == 0 )); then
  echo "No audio files found."
  exit 1
fi

IFS=$'\n' audio_files=($(printf '%s\n' "${audio_files[@]}" | sort -u))
unset IFS

case "$format" in
  txt|srt)
    ;;
  *)
    echo "Unsupported format: $format (use txt or srt)."
    exit 1
    ;;
 esac

for audio_path in "${audio_files[@]}"; do
  output_path="${audio_path%.*}.${format}"
  if [[ -e "$output_path" && $overwrite -eq 0 ]]; then
    echo "Skipping $audio_path (sidecar exists)"
    continue
  fi

  cmd=(yap transcribe "$audio_path" -o "$output_path")
  if [[ "$format" == "srt" ]]; then
    cmd+=(--srt)
  else
    cmd+=(--txt)
  fi
  if [[ -n "$locale" ]]; then
    cmd+=(--locale "$locale")
  fi
  if (( censor )); then
    cmd+=(--censor)
  fi

  "${cmd[@]}"
  echo "Wrote $output_path"
done
