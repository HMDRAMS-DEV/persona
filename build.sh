#!/bin/bash
# Compiles Persona.app into build/ with the Command Line Tools. No Xcode project.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$here/build/Persona.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/Persona/Info.plist" "$app/Contents/Info.plist"

sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
xcrun swiftc -O -sdk "$sdk" -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
    -module-name Persona -o "$app/Contents/MacOS/Persona" \
    $(find "$here/Persona" -name '*.swift')

codesign --force --sign - --identifier dev.persona.Persona "$app"
echo "built $app"
