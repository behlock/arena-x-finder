#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
destination="$PWD/build/$app_name.app"
verify_app "$destination"
swift_options+=(-c release)
swift build "${swift_options[@]}"
bin="$(swift build "${swift_options[@]}" --show-bin-path)"
mkdir -p "$PWD/build"
staging="$(mktemp -d "$PWD/build/.arena-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/ArenaFinder" "$app/Contents/MacOS/$app_name"
cp App/Info.plist "$app/Contents/Info.plist"
# Advertise exactly the image decoders available on this macOS version.
swift scripts/configure-image-service.swift "$app/Contents/Info.plist"
codesign --force --sign - "$app"
replace_app "$app" "$destination"
printf '%s\n' "$destination"
