#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
swift test "${swift_options[@]}"
plutil -lint App/Info.plist
bash -n scripts/*.sh
