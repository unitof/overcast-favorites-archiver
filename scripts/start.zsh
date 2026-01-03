#!/bin/zsh
set -euo pipefail

transcribe=0
transcribe_args=()

for arg in "$@"; do
  case "$arg" in
    -t|--transcribe)
      transcribe=1
      ;;
    *)
      transcribe_args+=("$arg")
      ;;
  esac
done

if (( transcribe )); then
  npm run sync
  npm run download
  npm run transcribe -- "${transcribe_args[@]}"
else
  npm run sync
  npm run download
fi
