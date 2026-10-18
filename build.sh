#!/bin/bash
# Construit Photogram.app et l'installe dans ~/Applications (ou dans le dossier donné : ./build.sh /chemin).
# Outils nécessaires : les outils de développement d'Apple (xcode-select --install). Xcode n'est pas nécessaire.
set -e
cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
APP="$DEST/Photogram.app"
command -v swiftc >/dev/null || { echo "Installe d'abord les outils d'Apple : xcode-select --install"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "Compilation…"
swiftc -O -swift-version 5 -parse-as-library main.swift -o "$T/Photogram"
echo "Icône…"
swift icon.swift assets/logo.png "$T/icon.png"
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o "$T/AppIcon.icns"
mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$T/Photogram" "$APP/Contents/MacOS/Photogram"
cp Info.plist "$APP/Contents/Info.plist"
cp "$T/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign -s - --force "$APP" >/dev/null 2>&1
echo "Prêt : $APP"
