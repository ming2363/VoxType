#!/usr/bin/env python3
import json
import os
import sys

sdk = sys.argv[1]
out = sys.argv[2]
iface_root = os.path.join(out, "ifaces")
os.makedirs(iface_root, exist_ok=True)
old = "swiftlang-6.2.3.3.2 clang-1700.6.3.2"
new = "swiftlang-6.2.4.1.4 clang-1700.6.4.2"
old2 = "Apple Swift version 6.2 effective-5.10"
new2 = "Apple Swift version 6.2.4 effective-5.10"
seen_real = set()
stack = [sdk]
dirs = []
while stack:
    current = stack.pop()
    try:
        names = os.listdir(current)
    except OSError:
        continue
    if any(name.endswith(".swiftinterface") for name in names):
        dirs.append(current)
    try:
        real = os.path.realpath(current)
    except OSError:
        continue
    if real in seen_real:
        continue
    seen_real.add(real)
    for name in names:
        path = os.path.join(current, name)
        if os.path.isdir(path):
            stack.append(path)

roots = []
for directory in dirs:
    contents = []
    for name in os.listdir(directory):
        src = os.path.join(directory, name)
        if os.path.isdir(src):
            continue
        if name.endswith(".swiftinterface"):
            key = directory.replace("/", "_") + "_" + name
            dst = os.path.join(iface_root, key)
            if not os.path.exists(dst):
                data = open(src, errors="replace").read().replace(old, new).replace(old2, new2)
                open(dst, "w").write(data)
            contents.append({"type": "file", "name": name, "external-contents": dst})
        else:
            contents.append({"type": "file", "name": name, "external-contents": src})
    roots.append({"type": "directory", "name": directory, "contents": contents})

empty = os.path.join(out, "empty.modulemap")
open(empty, "w").write("// avoid duplicate SwiftBridging\n")
swift_include = "/Library/Developer/CommandLineTools/usr/include/swift"
roots.append({
    "type": "directory",
    "name": swift_include,
    "contents": [
        {"type": "file", "name": "module.modulemap", "external-contents": empty},
        {"type": "file", "name": "bridging.modulemap", "external-contents": os.path.join(swift_include, "bridging.modulemap")},
        {"type": "file", "name": "bridging", "external-contents": os.path.join(swift_include, "bridging")},
    ],
})
json.dump({"version": 0, "roots": roots}, open(os.path.join(out, "overlay.yaml"), "w"))
print(f"overlay {len(roots)} dirs")
