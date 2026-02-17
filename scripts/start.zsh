#!/bin/zsh
set -euo pipefail

sync=1
download=1
transcribe=1
transcribe_args=()

usage() {
  cat <<'EOF'
Usage: npm start -- [options] [transcribe args...]

Runs sync + download + transcribe by default.

Options:
  -S, --skip-sync         Skip sync step
  -D, --skip-download     Skip download step
  -T, --skip-transcribe   Skip transcribe step
  -h, --help              Show this help

Any unrecognized arguments are forwarded to `npm run transcribe -- ...`.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    -S|--skip-sync)
      sync=0
      ;;
    -D|--skip-download)
      download=0
      ;;
    -T|--skip-transcribe)
      transcribe=0
      ;;
    *)
      transcribe_args+=("$arg")
      ;;
  esac
done

if (( sync )); then
  npm run sync
fi

if (( download )); then
  npm run download
fi

if (( transcribe )); then
  npm run transcribe -- "${transcribe_args[@]}"
fi
