# Overcast Favorites Archiver

Export Overcast favorites, download audio, and optionally generate transcript sidecars.

## Prerequisites

Homebrew packages (preferred: Brewfile):

```sh
brew bundle

# or, explicitly
brew bundle --file=Brewfile

# manual install (no Brewfile)
brew install sqlite-utils jq finnvoor/tools/yap
```

Notes:
- `sqlite-utils` is required for `npm run sync`.
- `jq` is required for `npm run download`.
- `yap` is required for `npm run transcribe`.

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
