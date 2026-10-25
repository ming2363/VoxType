#!/usr/bin/env python3
"""Check Windows dictation's clipboard boundary without reading the clipboard."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent
violations = []
for path in sorted(root.rglob("*.cs")):
    if "obj" in path.parts or "bin" in path.parts:
        continue
    source = path.read_text()
    if path == root / "VoxType.Windows/Program.cs":
        start = source.index("    private void CopyLastResult()")
        opening = source.index("{", start)
        depth, end = 1, opening + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        source = source[:start] + source[end:]
        source = source.replace("copy.Click += (_, _) => CopyLastResult();", "")
    if re.search(r"\bClipboard\b|\bOpenClipboard\b|\bSetClipboardData\b|\bCopyLastResult\s*\(", source):
        violations.append(str(path.relative_to(root)))
assert not violations, "Unexpected clipboard access: " + ", ".join(violations)
print("Windows clipboard boundary PASS: only the explicit tray menu Copy action accesses it.")
