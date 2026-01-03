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

sqlite-utils ~/Library/Containers/2EFFC350-6DCA-4E17-9FCC-4BBBC7C484C0/Data/Documents/db.sqlite "$(<./scripts/overcast_export_recommended_episodes.sql)" > favorites.json
zsh ./dlall.zsh

if (( transcribe )); then
  npm run transcribe -- "${transcribe_args[@]}"
fi
