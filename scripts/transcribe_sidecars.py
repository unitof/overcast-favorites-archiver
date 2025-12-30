#!/usr/bin/env python3
"""Generate timestamped, speaker-grouped sidecar transcripts for audio files.

Requires local models. This script uses whisperx for transcription, alignment,
and diarization. Ensure models are cached locally (or point to --model-dir)
for fully offline use.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
import datetime as dt
import os
from pathlib import Path
import re
import sys
import warnings
import collections
import inspect
import time
from typing import Callable, Dict, Iterable, List, Optional

warnings.filterwarnings(
    "ignore",
    category=SyntaxWarning,
    message=r".*invalid escape sequence.*",
    module=r"pyannote\..*",
)
warnings.filterwarnings(
    "ignore",
    category=UserWarning,
    message=r".*torchaudio\._backend\.list_audio_backends has been deprecated.*",
)
warnings.filterwarnings(
    "ignore",
    category=UserWarning,
    module=r"pyannote\.audio\.core\.io",
)
warnings.filterwarnings(
    "ignore",
    category=UserWarning,
    module=r"speechbrain\.utils\.torch_audio_backend",
)

_original_showwarning = warnings.showwarning


def _filtered_showwarning(message, category, filename, lineno, file=None, line=None):
    text = str(message)
    if issubclass(category, SyntaxWarning) and "invalid escape sequence" in text and "pyannote" in filename:
        return
    if issubclass(category, UserWarning) and "torchaudio._backend.list_audio_backends has been deprecated" in text:
        return
    return _original_showwarning(message, category, filename, lineno, file=file, line=line)


warnings.showwarning = _filtered_showwarning

AUDIO_EXTENSIONS = {
    ".mp3",
    ".m4a",
    ".m4b",
    ".wav",
    ".flac",
    ".aac",
    ".ogg",
    ".opus",
    ".mp4",
    ".mkv",
    ".mov",
}


class LineStatus:
    def __init__(self) -> None:
        self._last_len = 0

    def update(self, text: str) -> None:
        padded = text
        if len(text) < self._last_len:
            padded = text + (" " * (self._last_len - len(text)))
        self._last_len = len(text)
        print(f"\r{padded}", end="", file=sys.stderr, flush=True)

    def newline(self, text: Optional[str] = None) -> None:
        if text:
            self.update(text)
        if self._last_len:
            print(file=sys.stderr)
        self._last_len = 0


class ProgressPrinter:
    def __init__(
        self,
        total_segments: int,
        total_seconds: float,
        line_status: LineStatus,
        interval: float = 5.0,
    ) -> None:
        self.total_segments = max(0, total_segments)
        self.total_seconds = max(0.0, total_seconds)
        self.interval = interval
        self._last_print = 0.0
        self._line_status = line_status

    def update(self, done_segments: int, done_seconds: float, done_words: int) -> None:
        now = time.time()
        if done_segments >= self.total_segments:
            self._emit(done_segments, done_seconds, done_words)
            return
        if now - self._last_print < self.interval:
            return
        self._emit(done_segments, done_seconds, done_words)

    def _emit(self, done_segments: int, done_seconds: float, done_words: int) -> None:
        self._last_print = time.time()
        percent = 0.0
        if self.total_seconds > 0:
            percent = min(100.0, (done_seconds / self.total_seconds) * 100)
        progress_time = format_timestamp(done_seconds)
        total_time = format_timestamp(self.total_seconds)
        if self.total_segments > 0:
            self._line_status.update(
                f"Progress: {percent:5.1f}% ({progress_time}/{total_time}) "
                f"- segments {min(done_segments, self.total_segments)}/{self.total_segments}, "
                f"words {done_words}"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe audio files to timestamped, speaker-grouped sidecars."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=[
            "/Users/jacob/Library/CloudStorage/GoogleDrive-j@cobford.com/My Drive/Filing Cabinet/Podcast Archive/[My Overcast Favorites]"
        ],
        help="Files or directories to scan (default: Overcast Favorites archive).",
    )
    parser.add_argument(
        "--recursive",
        action="store_true",
        help="Recurse into subdirectories when scanning folders.",
    )
    parser.add_argument(
        "--extensions",
        default=",".join(sorted(AUDIO_EXTENSIONS)),
        help="Comma-separated list of audio extensions to include.",
    )
    parser.add_argument(
        "--format",
        choices=["txt", "srt", "vtt"],
        default="txt",
        help="Sidecar format to emit (default: txt).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing sidecar files instead of skipping.",
    )
    parser.add_argument(
        "--model",
        default="small.en",
        help="Whisper model name (default: small.en).",
    )
    parser.add_argument(
        "--model-dir",
        default=".models",
        help="Local directory for cached Whisper models (default: .models).",
    )
    parser.add_argument(
        "--device",
        default="auto",
        help="Device for inference: cpu, cuda, or auto (default: auto).",
    )
    parser.add_argument(
        "--compute-type",
        default="auto",
        help="Compute type for faster-whisper (default: auto).",
    )
    parser.add_argument(
        "--vad-method",
        choices=["pyannote", "silero"],
        default="silero",
        help="VAD method to use (default: silero).",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=16,
        help="Batch size for transcription (default: 16).",
    )
    parser.add_argument(
        "--language",
        default="en",
        help="Language code (default: en).",
    )
    parser.add_argument(
        "--no-align",
        action="store_true",
        help="Skip alignment step (not recommended for diarization).",
    )
    parser.add_argument(
        "--no-diarize",
        action="store_true",
        help="Disable diarization (speaker grouping).",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Disable model downloads (require local caches).",
    )
    parser.add_argument(
        "--hf-token",
        default=None,
        help="Hugging Face token for diarization models (or set HF_TOKEN).",
    )
    parser.add_argument(
        "--min-speakers",
        type=int,
        default=None,
        help="Minimum speakers for diarization.",
    )
    parser.add_argument(
        "--max-speakers",
        type=int,
        default=None,
        help="Maximum speakers for diarization.",
    )
    parser.add_argument(
        "--gap-seconds",
        type=float,
        default=2.5,
        help="Silence gap that starts a new paragraph (default: 2.5).",
    )
    parser.add_argument(
        "--max-words",
        type=int,
        default=120,
        help="Max words per paragraph before forcing a break (default: 120).",
    )
    return parser.parse_args()


def resolve_audio_files(paths: Iterable[str], extensions: Iterable[str], recursive: bool) -> List[Path]:
    exts = {ext.lower().strip() for ext in extensions if ext}
    files: List[Path] = []
    for path_str in paths:
        path = Path(path_str)
        if path.is_file():
            if path.suffix.lower() in exts:
                files.append(path)
            continue
        if path.is_dir():
            pattern = "**/*" if recursive else "*"
            for candidate in path.glob(pattern):
                if candidate.is_file() and candidate.suffix.lower() in exts:
                    files.append(candidate)
    return sorted(set(files))


def format_timestamp(seconds: float) -> str:
    total_seconds = max(0, int(round(seconds)))
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    secs = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def format_srt_timestamp(seconds: float) -> str:
    seconds = max(0.0, seconds)
    millis = int(round((seconds - int(seconds)) * 1000))
    total_seconds = int(seconds)
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    secs = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def format_vtt_timestamp(seconds: float) -> str:
    seconds = max(0.0, seconds)
    millis = int(round((seconds - int(seconds)) * 1000))
    total_seconds = int(seconds)
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    secs = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def clean_text(text: str) -> str:
    text = text.replace("\n", " ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def word_count(text: str) -> int:
    if not text:
        return 0
    return len(text.split())


def transcribe_with_progress(model, audio, args: argparse.Namespace, line_status: LineStatus) -> Dict[str, str]:
    import numpy as np
    import whisperx
    from faster_whisper.tokenizer import Tokenizer
    from whisperx.audio import SAMPLE_RATE
    from whisperx.asr import find_numeral_symbol_tokens
    from whisperx.vads import Vad, Pyannote

    if isinstance(audio, str):
        audio = whisperx.load_audio(audio)

    if not isinstance(audio, np.ndarray):
        audio = np.array(audio, dtype=np.float32)

    total_seconds = float(audio.shape[0]) / float(SAMPLE_RATE)

    line_status.update("Running VAD…")
    if issubclass(type(model.vad_model), Vad):
        waveform = model.vad_model.preprocess_audio(audio)
        merge_chunks = model.vad_model.merge_chunks
    else:
        waveform = Pyannote.preprocess_audio(audio)
        merge_chunks = Pyannote.merge_chunks

    vad_segments = model.vad_model({"waveform": waveform, "sample_rate": SAMPLE_RATE})
    vad_segments = merge_chunks(
        vad_segments,
        30,
        onset=model._vad_params["vad_onset"],
        offset=model._vad_params["vad_offset"],
    )

    if model.tokenizer is None:
        language = args.language or model.detect_language(audio)
        task = "transcribe"
        model.tokenizer = Tokenizer(
            model.model.hf_tokenizer,
            model.model.model.is_multilingual,
            task=task,
            language=language,
        )
    else:
        language = args.language or model.tokenizer.language_code
        task = model.tokenizer.task
        if task != model.tokenizer.task or language != model.tokenizer.language_code:
            model.tokenizer = Tokenizer(
                model.model.hf_tokenizer,
                model.model.model.is_multilingual,
                task=task,
                language=language,
            )

    if model.suppress_numerals:
        previous_suppress_tokens = model.options.suppress_tokens
        numeral_symbol_tokens = find_numeral_symbol_tokens(model.tokenizer)
        new_suppressed_tokens = numeral_symbol_tokens + model.options.suppress_tokens
        new_suppressed_tokens = list(set(new_suppressed_tokens))
        model.options = replace(model.options, suppress_tokens=new_suppressed_tokens)

    segments: List[dict] = []
    batch_size = args.batch_size or model._batch_size
    total_segments = len(vad_segments)
    progress = ProgressPrinter(
        total_segments=total_segments,
        total_seconds=total_seconds,
        line_status=line_status,
    )
    done_words = 0

    def data():
        for seg in vad_segments:
            f1 = int(seg["start"] * SAMPLE_RATE)
            f2 = int(seg["end"] * SAMPLE_RATE)
            yield {"inputs": audio[f1:f2]}

    for idx, out in enumerate(model.__call__(data(), batch_size=batch_size, num_workers=0)):
        text = out["text"]
        if batch_size in [0, 1, None]:
            text = text[0]
        segments.append(
            {
                "text": text,
                "start": round(vad_segments[idx]["start"], 3),
                "end": round(vad_segments[idx]["end"], 3),
            }
        )
        done_words += word_count(clean_text(text))
        progress.update(idx + 1, vad_segments[idx]["end"], done_words)

    if model.preset_language is None:
        model.tokenizer = None

    if model.suppress_numerals:
        model.options = replace(model.options, suppress_tokens=previous_suppress_tokens)

    return {"segments": segments, "language": language}


def group_segments(
    segments: List[dict],
    gap_seconds: float,
    max_words: int,
    progress: Optional[Callable[[int], None]] = None,
) -> List[dict]:
    grouped: List[dict] = []
    current: Optional[dict] = None
    processed_words = 0

    for seg in segments:
        text = clean_text(seg.get("text", ""))
        if not text:
            continue
        speaker = seg.get("speaker") or "SPEAKER_00"
        start = float(seg.get("start", 0.0))
        end = float(seg.get("end", start))

        if current is None:
            current = {
                "speaker": speaker,
                "start": start,
                "end": end,
                "text": text,
                "words": word_count(text),
            }
            processed_words += word_count(text)
            if progress:
                progress(processed_words)
            continue

        gap = start - float(current["end"])
        should_break = (
            speaker != current["speaker"]
            or gap >= gap_seconds
            or current["words"] >= max_words
        )

        if should_break:
            grouped.append(current)
            current = {
                "speaker": speaker,
                "start": start,
                "end": end,
                "text": text,
                "words": word_count(text),
            }
        else:
            current["text"] = f"{current['text']} {text}"
            current["end"] = end
            current["words"] += word_count(text)

        processed_words += word_count(text)
        if progress:
            progress(processed_words)

    if current is not None:
        grouped.append(current)

    return grouped


class WordProgress:
    def __init__(self, total_words: int, line_status: LineStatus, label: str = "Processing") -> None:
        self.total = max(0, total_words)
        self.label = label
        self._last_print = 0
        self._line_status = line_status

    def update(self, done_words: int, force: bool = False) -> None:
        if self.total == 0:
            return
        if not force and done_words - self._last_print < 50:
            return
        done_words = min(done_words, self.total)
        self._last_print = done_words
        self._line_status.update(f"{self.label}: {done_words}/{self.total} words")

    def finish(self) -> None:
        self.update(self.total, force=True)


def map_speakers(paragraphs: List[dict]) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for para in paragraphs:
        label = para["speaker"]
        if label not in mapping:
            mapping[label] = f"Speaker {len(mapping) + 1}"
    return mapping


def write_txt(
    output_path: Path,
    audio_path: Path,
    paragraphs: List[dict],
    metadata: Dict[str, str],
) -> None:
    speaker_map = map_speakers(paragraphs)
    lines: List[str] = []
    lines.append("# Transcription")
    lines.append(f"# Audio: {audio_path}")
    for key, value in metadata.items():
        lines.append(f"# {key}: {value}")
    lines.append("")

    for para in paragraphs:
        timestamp = format_timestamp(para["start"])
        speaker = speaker_map.get(para["speaker"], para["speaker"])
        lines.append(f"[{timestamp}] {speaker}")
        lines.append(para["text"])
        lines.append("")

    output_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def write_srt(
    output_path: Path,
    paragraphs: List[dict],
) -> None:
    speaker_map = map_speakers(paragraphs)
    lines: List[str] = []
    for idx, para in enumerate(paragraphs, start=1):
        start = format_srt_timestamp(para["start"])
        end = format_srt_timestamp(para["end"])
        speaker = speaker_map.get(para["speaker"], para["speaker"])
        lines.append(str(idx))
        lines.append(f"{start} --> {end}")
        lines.append(f"{speaker}: {para['text']}")
        lines.append("")
    output_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def write_vtt(
    output_path: Path,
    paragraphs: List[dict],
    metadata: Dict[str, str],
) -> None:
    speaker_map = map_speakers(paragraphs)
    lines: List[str] = ["WEBVTT", ""]
    for key, value in metadata.items():
        lines.append(f"NOTE {key}: {value}")
    lines.append("")
    for para in paragraphs:
        start = format_vtt_timestamp(para["start"])
        end = format_vtt_timestamp(para["end"])
        speaker = speaker_map.get(para["speaker"], para["speaker"])
        lines.append(f"{start} --> {end}")
        lines.append(f"{speaker}: {para['text']}")
        lines.append("")
    output_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def transcribe_audio(path: Path, args: argparse.Namespace, line_status: LineStatus) -> Dict[str, str]:
    try:
        import whisperx
    except ImportError as exc:  # pragma: no cover - runtime dependency
        raise SystemExit(
            "whisperx is required. Install with: pip install whisperx"
        ) from exc
    try:
        import logging

        logging.getLogger("pytorch_lightning.utilities.migration.utils").setLevel(logging.WARNING)
        logging.getLogger("whisperx.vads.pyannote").setLevel(logging.WARNING)
    except Exception:
        pass
    try:
        import pyannote.audio.utils.version as _py_version
        import pyannote.audio.core.model as _py_model

        def _silent_version_check(*_args, **_kwargs):
            return None

        _py_version.check_version = _silent_version_check
        _py_model.check_version = _silent_version_check
    except Exception:
        pass
    try:
        from huggingface_hub.errors import LocalEntryNotFoundError
    except Exception:  # pragma: no cover - optional dependency
        LocalEntryNotFoundError = None  # type: ignore[assignment]

    try:
        import torch
        import typing as _typing
        from omegaconf import DictConfig, ListConfig, nodes as _oc_nodes
        from omegaconf import base as _oc_base

        add_safe = getattr(torch.serialization, "add_safe_globals", None)
        if callable(add_safe):
            safe_nodes = [
                obj
                for obj in vars(_oc_nodes).values()
                if inspect.isclass(obj) and obj.__module__ == _oc_nodes.__name__
            ]
            safe_base = [
                obj
                for obj in vars(_oc_base).values()
                if inspect.isclass(obj) and obj.__module__ == _oc_base.__name__
            ]
            torch_safe = []
            torch_version_cls = getattr(torch.torch_version, "TorchVersion", None)
            if torch_version_cls is not None:
                torch_safe.append(torch_version_cls)
            pyannote_safe = []
            try:
                from pyannote.audio.core import model as _pyannote_model
                from pyannote.audio.core import task as _pyannote_task

                pyannote_safe = []
                for module in (_pyannote_model, _pyannote_task):
                    pyannote_safe.extend(
                        [
                            obj
                            for obj in vars(module).values()
                            if inspect.isclass(obj) and obj.__module__ == module.__name__
                        ]
                    )
            except Exception:
                pyannote_safe = []

            add_safe(
                [
                    ListConfig,
                    DictConfig,
                    *safe_base,
                    _typing.Any,
                    list,
                    int,
                    float,
                    bool,
                    str,
                    bytes,
                    dict,
                    tuple,
                    set,
                    frozenset,
                    collections.defaultdict,
                    *safe_nodes,
                    *torch_safe,
                    *pyannote_safe,
                ]
            )
    except Exception:
        # Best-effort: if torch/omegaconf isn't available yet, let whisperx raise.
        pass

    device = args.device
    if device == "auto":
        device = "cuda" if os.environ.get("CUDA_VISIBLE_DEVICES") else "cpu"

    model_dir = Path(args.model_dir) if args.model_dir else None
    if model_dir:
        model_dir.mkdir(parents=True, exist_ok=True)

    try:
        line_status.update("Loading model…")
        model = whisperx.load_model(
            args.model,
            device,
            compute_type=args.compute_type,
            download_root=str(model_dir) if model_dir else None,
            vad_method=args.vad_method,
        )
    except Exception as exc:
        if args.offline and LocalEntryNotFoundError and isinstance(exc, LocalEntryNotFoundError):
            raise SystemExit(
                "Model files not found locally (offline mode). Run once online to cache models, "
                "or remove --offline."
            ) from exc
        if args.offline and ("huggingface.co" in str(exc) or "ConnectionError" in str(exc)):
            raise SystemExit(
                "Model download blocked (offline mode). Run once online to cache models, "
                "or remove --offline."
            ) from exc
        raise

    audio = whisperx.load_audio(str(path))
    result = transcribe_with_progress(model, audio, args, line_status)

    if not args.no_align:
        line_status.update("Aligning transcript…")
        align_model, metadata = whisperx.load_align_model(
            language_code=result.get("language"),
            device=device,
        )
        result = whisperx.align(
            result["segments"],
            align_model,
            metadata,
            audio,
            device,
            return_char_alignments=False,
        )

    if not args.no_diarize:
        token = args.hf_token or os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
        if not token:
            raise SystemExit(
                "Diarization requires a Hugging Face token. Provide --hf-token or set HF_TOKEN."
            )
        line_status.update("Diarizing speakers…")
        diarize_model = whisperx.DiarizationPipeline(
            use_auth_token=token,
            device=device,
        )
        diarize_kwargs = {}
        if args.min_speakers is not None:
            diarize_kwargs["min_speakers"] = args.min_speakers
        if args.max_speakers is not None:
            diarize_kwargs["max_speakers"] = args.max_speakers
        diarize_segments = diarize_model(audio, **diarize_kwargs)
        result = whisperx.assign_word_speakers(diarize_segments, result)

    return {
        "language": result.get("language") or args.language or "unknown",
        "segments": result.get("segments", []),
    }


def build_metadata(args: argparse.Namespace, language: str) -> Dict[str, str]:
    now = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    metadata = {
        "Model": args.model,
        "Language": language,
        "Transcribed": now,
    }
    if args.no_diarize:
        metadata["Diarization"] = "disabled"
    else:
        metadata["Diarization"] = "enabled"
    return metadata


def main() -> int:
    args = parse_args()
    if args.offline:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    extensions = [ext if ext.startswith(".") else f".{ext}" for ext in args.extensions.split(",")]
    audio_files = resolve_audio_files(args.paths, extensions, args.recursive)

    if not audio_files:
        print("No audio files found.")
        return 1

    line_status = LineStatus()
    for audio_path in audio_files:
        output_path = audio_path.with_suffix(f".{args.format}")
        if output_path.exists() and not args.overwrite:
            line_status.newline()
            print(f"Skipping {audio_path} (sidecar exists)")
            continue

        line_status.update(f"Working on {audio_path.name}…")
        result = transcribe_audio(audio_path, args, line_status)
        total_words = sum(word_count(clean_text(seg.get("text", ""))) for seg in result["segments"])
        progress = WordProgress(total_words, line_status, label="Processing transcript")
        paragraphs = group_segments(
            result["segments"],
            gap_seconds=args.gap_seconds,
            max_words=args.max_words,
            progress=progress.update,
        )
        progress.finish()
        metadata = build_metadata(args, result["language"])

        if args.format == "txt":
            write_txt(output_path, audio_path, paragraphs, metadata)
        elif args.format == "srt":
            write_srt(output_path, paragraphs)
        elif args.format == "vtt":
            write_vtt(output_path, paragraphs, metadata)
        else:
            raise SystemExit(f"Unsupported format: {args.format}")

        line_status.newline(f"Wrote {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
