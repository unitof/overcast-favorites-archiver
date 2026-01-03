# AGENTS.md — overcast-favorites-archiver

## Repo orientation (fast start)
- `npm start` runs sync + download (and optional transcribe via `-t|--transcribe`).
- `npm run sync` exports Overcast favorites into `favorites.json`.
- `npm run download` fetches media for each favorite.
- `scripts/` holds the task runners; prefer editing these over top-level wrappers.

## Script organization rules
- Keep shell entrypoints in `scripts/` and call them from `package.json` scripts.
- Keep one responsibility per script (sync vs download vs transcribe).
- When adding a new task, follow the pattern: `scripts/<task>.zsh` + `npm run <task>`.
- Preserve existing behavior: sync → download ordering matters for `npm start`.

## Key files
- `scripts/sync.zsh`: exports favorites using `sqlite-utils` and a SQL file.
- `scripts/download.zsh`: thin wrapper around `dlall.zsh`.
- `dlall.zsh`: main download loop; handles failures and reporting.
- `scripts/start.zsh`: orchestration and optional transcription.

## Dependencies
- `sqlite-utils` for sync (from Homebrew).
- `jq` for download (from Homebrew).

## Data locations
- Overcast DB path is hardcoded in `scripts/sync.zsh`.
- Overcast uses SQLite WAL; if you copy the DB for inspection, copy `db.sqlite`, `db.sqlite-wal`, and `db.sqlite-shm` together.
- Output JSON is `favorites.json` in repo root.
- Download destination is hardcoded in `dlall.zsh` (Google Drive path).

## Logging and reports
- Prefer summary reports at the end of runs (e.g., grouped failures).
- Keep per-item logs short to avoid noisy runs.
- If you add new failure modes, include them in the final report.

## Safety / behavior
- Avoid deleting existing files; only remove partial downloads on failure.
- Preserve the “skip if file exists” behavior to prevent re-downloads.
- Keep curl retries and redirect handling intact unless changing for a reason.

## How to approach new tasks
- Start by reading the relevant script in `scripts/` and any top-level helper it calls.
- Keep changes small and localized; avoid duplicating logic across scripts.
- If you add output/logging, prefer clear, grouped summaries at the end of runs.

## Suggested quick checks
- If you change sync logic, verify `favorites.json` still populates.
- If you change download logic, test with a small subset of favorites.

## Testing (prefer non-destructive)
- Default: run the smallest surface area that exercises your change.
- For download changes, use a tiny `favorites.json` fixture (copy and trim) and point `dlall.zsh` at it temporarily or via a local override.
- For sync changes, run `npm run sync` and confirm `favorites.json` updates without modifying other files.
- Avoid deleting or moving existing archives; keep “skip if file exists” in place.

## Manual sync prerequisite
- Launch Overcast.app first to trigger a favorites sync before running `npm run sync`.
- If a new favorite doesn’t appear, manually trigger sync in Overcast, then wait ~30–60s and recheck.
