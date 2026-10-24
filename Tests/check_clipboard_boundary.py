#!/usr/bin/env python3
"""Guard the no-clipboard dictation boundary without reading the real clipboard."""
from pathlib import Path
import re
import sys


def remove_method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[:start] + source[end:]


def check(root):
    violations = []
    for path in sorted((root / "Sources").rglob("*")):
        if path.suffix not in {".swift", ".c", ".h"}:
            continue
        source = path.read_text()
        # Only the explicit menu action may copy the last result.
        if path.name == "AppModel.swift":
            source = remove_method(source, "func copyLastResult()")
        elif path.name == "MenuAndSettings.swift":
            source = remove_method(source, "@objc private func copyResult()")
        if re.search(r"NSPasteboard|\bPasteboard[A-Z]\w*|\bpbcopy\b|\bpbpaste\b|\bcopyLastResult\s*\(", source):
            violations.append(str(path.relative_to(root)))
    if violations:
        raise AssertionError("Automatic code may access clipboard: " + ", ".join(violations))
    print("Clipboard boundary passed: only the explicit Copy Last Result action can access it.")


if __name__ == "__main__":
    check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1])
