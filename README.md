# Overcast Favorites Archiver

Export Overcast favorites, download audio, and optionally generate transcript sidecars.

## Prerequisites

Homebrew packages:

```sh
brew install sqlite-utils jq uv ffmpeg python@3.12
```

Notes:
- `sqlite-utils` is required for `npm run sync`.
- `jq` is required for `npm run download`.
- `uv` + `ffmpeg` are required for `npm run transcribe`.
- Python 3.10-3.12 is required for `npm run transcribe:setup`.

## Commands

```sh
npm run sync       # export favorites to favorites.json
npm run download   # download favorites audio files
npm run transcribe # generate transcript sidecars
```

`npm start` runs sync + download. To include transcription:

```sh
npm start -- -t
```

`--transcribe` also works.

## Transcription setup

```sh
npm run transcribe:setup
```

This creates the virtual environment and installs `requirements.txt`.
