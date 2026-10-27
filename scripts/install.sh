#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
application_directory="${1:-$HOME/Applications}"
destination="$application_directory/$app_name.app"
verify_app "$destination"
bash scripts/build-app.sh
swift scripts/stop-app.swift
mkdir -p "$application_directory"
launch_services=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$(cd "$application_directory" && pwd)/$app_name.app" != "$PWD/build/$app_name.app" ]; then
    replace_app "build/$app_name.app" "$destination"
    "$launch_services" -u "$PWD/build/$app_name.app" >/dev/null 2>&1 || true
fi
"$launch_services" -f "$destination"
pluginkit -a "$destination/Contents/PlugIns/ArenaProvider.appex"
printf 'Installed %s\nOpen it once to connect your Are.na account.\n' "$destination"
