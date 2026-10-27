#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
identity="${ARENA_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([A-Fa-f0-9]*\) "Apple Development:.*$/\1/p' | head -n 1)}"
if [ -z "$identity" ]; then
    printf 'A valid Apple Development signing identity is required for Finder integration. Add your developer account in Xcode, or set ARENA_SIGNING_IDENTITY.\n' >&2
    exit 1
fi
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
extension="$app/Contents/PlugIns/ArenaProvider.appex"
mkdir -p "$extension/Contents/MacOS"
cp App/Provider-Info.plist "$extension/Contents/Info.plist"
xcrun clang -mmacosx-version-min=13.0 -c App/ProviderMain.c -o "$staging/ProviderMain.o"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" "$staging/ProviderMain.o" "$bin/libArenaProvider.a" \
    -Xlinker -force_load -Xlinker "$bin/libArenaProvider.a" -framework FileProvider -framework AppKit -framework Security -o "$extension/Contents/MacOS/ArenaProvider"
# Extract the actual signing team; no personal team ID is committed to source.
codesign --force --sign "$identity" "$extension"
team="$(codesign -dv --verbose=4 "$extension" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ -z "$team" ] || [ "$team" = 'not set' ]; then
    printf 'The signing identity must belong to an Apple developer team.\n' >&2
    exit 1
fi
python3 - "$app" "$extension" "$staging" "$team" <<'PY'
import pathlib, plistlib, sys
app, extension, staging = map(pathlib.Path, sys.argv[1:4])
group = sys.argv[4] + '.com.behlock.arena-x-finder'
for bundle in [app, extension]:
    path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    info['ArenaAppGroup'] = group
    info['CFBundleShortVersionString'] = '0.2.0'
    info['CFBundleVersion'] = '2'
    if bundle == extension:
        info['NSExtension']['NSExtensionFileProviderDocumentGroup'] = group
    path.write_bytes(plistlib.dumps(info))
for name, sandboxed in [('app', False), ('provider', True)]:
    entitlements = {'com.apple.security.application-groups': [group]}
    if sandboxed:
        entitlements.update({'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True})
    (staging / (name + '.entitlements')).write_bytes(plistlib.dumps(entitlements))
PY
codesign --force --sign "$identity" --options runtime --entitlements "$staging/provider.entitlements" "$extension"
codesign --force --sign "$identity" --options runtime --entitlements "$staging/app.entitlements" "$app"
codesign --verify --deep --strict "$app"
replace_app "$app" "$destination"
printf '%s\n' "$destination"
