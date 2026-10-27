#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
application_directory="${1:-$HOME/Applications}"
destination="$application_directory/$app_name.app"
verify_app "$destination"
bash scripts/build-app.sh
launchctl bootout "gui/$(id -u)/com.behlock.arena-x-finder.thumbnails" >/dev/null 2>&1 || true
swift scripts/stop-app.swift
mkdir -p "$application_directory"
launch_services=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$(cd "$application_directory" && pwd)/$app_name.app" != "$PWD/build/$app_name.app" ]; then
    replace_app "build/$app_name.app" "$destination"
    "$launch_services" -u "$PWD/build/$app_name.app" >/dev/null 2>&1 || true
fi
"$launch_services" -f "$destination"
pluginkit -a "$destination/Contents/PlugIns/ArenaProvider.appex"
agent="$HOME/Library/LaunchAgents/com.behlock.arena-x-finder.thumbnails.plist"
mkdir -p "$(dirname "$agent")"
python3 - "$agent" "$destination" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
executable = str(pathlib.Path(sys.argv[2]) / 'Contents/Helpers/ArenaThumbnailWorker.app/Contents/MacOS/ArenaThumbnailWorker')
path.write_bytes(plistlib.dumps({
    'Label': 'com.behlock.arena-x-finder.thumbnails',
    'ProgramArguments': [executable, '--thumbnail-worker'],
    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 30,
    'ProcessType': 'Background',
}))
PY
launchctl bootstrap "gui/$(id -u)" "$agent"
printf 'Installed %s\nOpen it once to connect your Are.na account.\n' "$destination"
