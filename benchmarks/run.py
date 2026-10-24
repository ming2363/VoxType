#!/usr/bin/env python3
"""Dependency-free, opt-in ASR benchmark. No application settings are changed."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
import wave
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tokens(text, category):
    text = unicodedata.normalize("NFKC", text).casefold()
    if category == "zh":
        return [c for c in text if c.isalnum()]
    # Chinese characters each count once; contiguous Latin words/numbers count once.
    return re.findall(r"[a-z]+(?:'[a-z]+)?|\d+|[\u3400-\u9fff]", text)


def edit_distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        nxt = [i]
        for j, y in enumerate(b, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j - 1] + (x != y)))
        row = nxt
    return row[-1]


def percentile(values, q):
    values = sorted(values)
    if not values:
        return None
    p = (len(values) - 1) * q
    lo, hi = math.floor(p), math.ceil(p)
    return values[lo] + (values[hi] - values[lo]) * (p - lo)


def summarize(rows):
    result = {"requests": len(rows), "successful": sum(r["ok"] for r in rows)}
    for category, metric in [("zh", "CER"), ("en", "WER"), ("mixed", "MER")]:
        subset = [r for r in rows if r["category"] == category]
        refs = [tokens(r["reference"], category) for r in subset]
        # Failures count as an empty transcript, not as a silently discarded case.
        hypotheses = [tokens(r["transcript"] if r["ok"] else "", category) for r in subset]
        total = sum(map(len, refs))
        edits = sum(edit_distance(a, b) for a, b in zip(refs, hypotheses))
        result[category] = {"metric": metric, "requests": len(subset), "reference_units": total,
                            "edits": edits, "error_rate_pct": 100 * edits / total if total else None}
    for name in ["first_text_ms", "final_tail_ms", "handshake_ms"]:
        vals = [r[name] for r in rows if r["ok"] and isinstance(r.get(name), (int, float))]
        result[name] = {"n": len(vals), "p50": percentile(vals, .5), "p95": percentile(vals, .95)}
    return result


def prepare(samples):
    folder = HERE / "audio"
    folder.mkdir(exist_ok=True)
    for sample in samples:
        voice = "Samantha" if sample["category"] == "en" else "Tingting"
        wav = folder / (sample["id"] + ".wav")
        meta = folder / (sample["id"] + ".json")
        signature = {"text": sample["text"], "voice": voice, "rate": 165, "padding_seconds": .2}
        if not wav.exists() or not meta.exists() or json.loads(meta.read_text()) != signature:
            subprocess.run(["/usr/bin/say", "-v", voice, "-r", "165", "-o", str(wav),
                            "--file-format=WAVE", "--data-format=LEI16@16000", "--channels=1",
                            sample["text"]], check=True, capture_output=True)
            meta.write_text(json.dumps(signature, ensure_ascii=False), encoding="utf-8")
        with wave.open(str(wav), "rb") as source:
            if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
                raise ValueError("Unexpected generated audio format")
            raw = source.readframes(source.getnframes())
        # Keep the original synthetic audio; append 200ms silence identically for each run.
        raw += bytes(6400)
        pcm = folder / (sample["id"] + ".pcm")
        pcm.write_bytes(raw)
        sample["audio_seconds"] = len(raw) / 32000
        sample["audio_sha256"] = digest(pcm)
        sample["voice"] = voice
    return folder


def build():
    out = ROOT / ".build" / "benchmark"
    out.mkdir(parents=True, exist_ok=True)
    sdk = os.environ.get("SDK") or subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    common = ["-sdk", sdk, "-target", "arm64-apple-macosx15.0",
              "-module-cache-path", str(out / "module-cache"), "-I", str(ROOT / "Sources/CGZip/include")]
    # Reuse a local toolchain compatibility overlay only when one already exists.
    # It is excluded from publication and is not needed by a matching Xcode/SDK.
    overlay = ROOT / ".build/sdk-overlay/overlay.yaml"
    if overlay.exists():
        common += ["-vfsoverlay", str(overlay)]
    def command(args):
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
    command(["clang", "-c", str(ROOT / "Sources/CGZip/cgzip.c"), "-I", str(ROOT / "Sources/CGZip/include"), "-o", str(out / "cgzip.o")])
    core = sorted((ROOT / "Sources/VoxTypeCore").glob("*.swift"))
    command(["swiftc", *common, "-O", "-wmo", "-module-name", "VoxTypeCore", "-emit-module",
             "-emit-module-path", str(out / "VoxTypeCore.swiftmodule"), "-c", "-o", str(out / "VoxTypeCore.o"), *map(str, core)])
    shutil.copyfile(HERE / "stream.swift", out / "main.swift")
    runner = out / "stream-probe"
    command(["swiftc", *common, "-O", "-I", str(out), str(ROOT / "Sources/VoxTypeApp/DoubaoASRClient.swift"),
             str(out / "main.swift"), str(out / "VoxTypeCore.o"), str(out / "cgzip.o"), "-Xlinker", "-lz", "-o", str(runner)])
    return runner, core


def self_test():
    assert edit_distance([], ["a"]) == 1
    assert edit_distance(["a", "b"], ["a", "c"]) == 1
    assert edit_distance(["a", "b"], ["b"]) == 1
    assert tokens("ＡＰＩ，你好！", "mixed") == ["api", "你", "好"]
    assert tokens("Hello, WORLD!", "en") == ["hello", "world"]
    assert tokens("你，好。", "zh") == ["你", "好"]
    assert percentile([1, 2, 3], .5) == 2
    failed = summarize([{"ok": False, "category": "en", "reference": "hello world", "transcript": "hello world"}])
    assert failed["en"]["error_rate_pct"] == 100
    print("Scorer checks passed (including failed-request accounting).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--score", type=Path, help="Summarize an existing result without API calls")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--max-audio-seconds", type=float, default=600)
    parser.add_argument("--output", type=Path, default=HERE / "local/latest.json")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.score:
        print(json.dumps(summarize(json.loads(args.score.read_text())["rows"]), ensure_ascii=False, indent=2))
        return
    corpus = json.loads((HERE / "corpus.json").read_text())
    if args.limit < 1 or args.repeats < 1:
        parser.error("limit and repeats must be positive")
    samples = corpus["samples"][:args.limit]
    folder = prepare(samples)
    budget = sum(s["audio_seconds"] for s in samples) * args.repeats
    print(f"Prepared {len(samples)} original synthetic samples; requested audio: {budget:.1f}s", flush=True)
    if args.prepare_only:
        return
    if budget > args.max_audio_seconds:
        parser.error("Audio budget exceeded; lower repeats/limit or explicitly raise the budget")
    runner, core = build()
    # Read only this application's credential; capture it in memory and never print stderr.
    credential = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "app.voxtype.mac",
                                 "-a", "doubao-api-key", "-w"], capture_output=True, timeout=15)
    if credential.returncode != 0 or not credential.stdout.strip():
        raise RuntimeError("VoxType credential unavailable. Save it in app settings; do not paste it into an issue.")
    key = credential.stdout.strip()
    tracked = core + [ROOT / "Sources/VoxTypeApp/DoubaoASRClient.swift", HERE / "stream.swift", HERE / "run.py", HERE / "corpus.json"]
    report = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
              "product": "VoxType ASR transport + reducer (not UI end-to-end)",
              "sample_kind": "macOS synthetic speech; not human microphone recordings",
              "source_sha256": {str(p.relative_to(ROOT)): digest(p) for p in tracked},
              "settings": {"repeats": args.repeats, "packet_ms": 200, "final_timeout_seconds": 3,
                           "enable_nonstream": True, "rate": 16000, "audio_budget_seconds": args.max_audio_seconds},
              "rows": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for repeat in range(1, args.repeats + 1):
        for sample in samples:
            proc = subprocess.run([str(runner), str(folder / (sample["id"] + ".pcm"))], input=key,
                                  capture_output=True, timeout=math.ceil(sample["audio_seconds"]) + 18)
            try:
                row = json.loads(proc.stdout)
            except (ValueError, UnicodeDecodeError):
                row = {"ok": False, "error": "probe_failed", "transcript": ""}
            # Defense in depth: a credential echoed by a remote endpoint must never reach a file.
            row = json.loads(json.dumps(row).replace(key.decode("utf-8"), "[redacted]"))
            row.update({"id": sample["id"], "category": sample["category"], "reference": sample["text"],
                        "repeat": repeat, "voice": sample["voice"], "audio_sha256": sample["audio_sha256"]})
            report["rows"].append(row)
            report["summary"] = summarize(report["rows"])
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"{repeat}/{args.repeats} {sample['id']}: {'ok' if row['ok'] else row.get('error', 'failed')}", flush=True)
            # Stop on credentials/quota/network failure rather than repeatedly spending or retrying.
            if row.get("error") in ["authentication", "quota", "network", "handshake_timeout", "server_error"]:
                raise RuntimeError("Stopped after a service failure; partial result retained without credentials.")
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError) as error:
        # Avoid subprocess command/output dumps on failures involving credentials.
        print(f"Benchmark stopped: {type(error).__name__}. Check setup and sanitized partial results.", file=sys.stderr)
        sys.exit(1)
