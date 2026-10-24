#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sign_app() {
  local target="$1"
  local sign_dir="${VOXTYPE_SIGN_DIR:-$HOME/.config/voxtype}"
  local keychain="$sign_dir/signing.keychain-db"
  local passfile="$sign_dir/signing.pass"
  local identity="VoxType Local Codesign"
  mkdir -p "$sign_dir"
  chmod 700 "$sign_dir"
  if [[ ! -f "$keychain" || ! -f "$passfile" ]]; then
    create_signing_identity "$sign_dir" "$keychain" "$passfile"
  fi
  local pass
  pass="$(<"$passfile")"
  local saved
  saved="$(security list-keychains -d user)"
  security unlock-keychain -p "$pass" "$keychain"
  security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
  local code=0
  codesign --force --sign "$identity" --keychain "$keychain" \
    --entitlements "$ROOT/Resources/entitlements.plist" "$target" || code=$?
  # shellcheck disable=SC2086
  eval security list-keychains -d user -s $saved
  return "$code"
}

create_signing_identity() {
  local sign_dir="$1"
  local keychain="$2"
  local passfile="$3"
  local pass
  pass="$(openssl rand -hex 16)"
  umask 077
  printf '%s' "$pass" > "$passfile"
  local conf="$sign_dir/codesign.cnf"
  local key="$sign_dir/signing.key"
  local cert="$sign_dir/signing.crt"
  local p12="$sign_dir/signing.p12"
  cat > "$conf" << 'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VoxType Local Codesign
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 3650 -nodes -config "$conf" >/dev/null 2>&1
  openssl pkcs12 -export -legacy -out "$p12" -inkey "$key" -in "$cert" -passout "pass:$pass" >/dev/null 2>&1
  local saved
  saved="$(security list-keychains -d user)"
  security create-keychain -p "$pass" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$pass" "$keychain"
  security import "$p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$keychain" >/dev/null
  # shellcheck disable=SC2086
  eval security list-keychains -d user -s $saved
  rm -f "$p12"
}

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk}"
OVERLAY="${OVERLAY:-$ROOT/.build/sdk-overlay/overlay.yaml}"
CACHE="${CACHE:-$ROOT/.build/module-cache}"
OUT="$ROOT/.build/manual"
mkdir -p "$OUT" "$CACHE" "$ROOT/.build/sdk-overlay"
python3 "$ROOT/Scripts/make-sdk-overlay.py" "$SDK" "$ROOT/.build/sdk-overlay"
clang -c "$ROOT/Sources/CGZip/cgzip.c" -I "$ROOT/Sources/CGZip/include" -o "$OUT/cgzip.o"
COMMON=(
  -sdk "$SDK" -target arm64-apple-macosx15.0
  -vfsoverlay "$ROOT/.build/sdk-overlay/overlay.yaml"
  -module-cache-path "$CACHE"
  -I "$ROOT/Sources/CGZip/include"
)
swiftc "${COMMON[@]}" -O -wmo \
  -module-name VoxTypeCore \
  -emit-module -emit-module-path "$OUT/VoxTypeCore.swiftmodule" \
  -c -o "$OUT/VoxTypeCore.o" \
  "$ROOT/Sources/VoxTypeCore/"*.swift
swiftc "${COMMON[@]}" -typecheck -I "$OUT" \
  "$ROOT/Sources/VoxTypeApp/"*.swift
swiftc "${COMMON[@]}" -O -I "$OUT" \
  "$ROOT/Sources/VoxTypeApp/"*.swift \
  "$OUT/VoxTypeCore.o" "$OUT/cgzip.o" \
  -Xlinker -lz \
  -o "$OUT/VoxType"
APP="$ROOT/dist/VoxType.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/VoxType" "$APP/Contents/MacOS/VoxType"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sign_app "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/VoxType.app"
cp -R "$APP" "$HOME/Applications/VoxType.app"
sign_app "$HOME/Applications/VoxType.app"
echo "built $APP"
echo "installed $HOME/Applications/VoxType.app"
