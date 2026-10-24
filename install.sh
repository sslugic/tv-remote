#!/bin/sh
# Installs the built app on your iPhone. Find your device ID with: xcrun devicectl list devices
# Usage: IPHONE_ID=<device id> ./install.sh   (unlock the phone first)
cd "$(dirname "$0")"
: "${IPHONE_ID:?Set IPHONE_ID to your iPhone's device identifier}"
xcrun devicectl device install app --device "$IPHONE_ID" build/Build/Products/Release-iphoneos/TVRemote.app
