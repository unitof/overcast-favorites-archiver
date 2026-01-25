#!/bin/zsh
set -euo pipefail
setopt extended_glob null_glob

yap_path="$(command -v yap 2>/dev/null || true)"
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
      for file in "$path"/**/*(.N); do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done
    else
      for file in "$path"/*(.N); do
        if is_audio "$file"; then
          audio_files+=("$file")
        fi
      done
    fi
    continue
  fi
  echo "Path not found: $path"
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

failures=()

for audio_path in "${audio_files[@]}"; do
  output_path="${audio_path%.*}.${format}"
  if [[ -e "$output_path" && $overwrite -eq 0 ]]; then
    echo "Skipping $audio_path (sidecar exists)"
    continue
  fi

  echo "Transcribing $audio_path"
  cmd=("$yap_path" transcribe "$audio_path" -o "$output_path")
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
  status=$?
  set -e

  if (( status == 0 )); then
    echo "Wrote $output_path"
  else
    echo "yap failed for $audio_path (exit $status); skipping"
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
