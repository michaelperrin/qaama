#!/bin/sh
# Builds the probe as a small app bundle signed ad hoc with one set of entitlements, so the same
# code can be run with and without each right.
#
#   ./build.sh open         no sandbox (baseline)
#   ./build.sh sandbox      App Sandbox alone
#   ./build.sh usb          App Sandbox + com.apple.security.device.usb
#   ./build.sh qaama        the entitlements Qaama ships today
#
# The bundle lands in build/<variant>/CardImportProbe.app.
set -eu

variant="${1:?usage: build.sh open|sandbox|usb|qaama}"
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/build/$variant/CardImportProbe.app"
entitlements="$here/build/$variant/probe.entitlements"

key() { printf '\t<key>%s</key>\n\t<true/>\n' "$1"; }
case "$variant" in
  open) rights="" ;;
  sandbox) rights="$(key com.apple.security.app-sandbox)" ;;
  usb) rights="$(key com.apple.security.app-sandbox; key com.apple.security.device.usb)" ;;
  qaama) rights="$(key com.apple.security.app-sandbox
                   key com.apple.security.files.bookmarks.app-scope
                   key com.apple.security.files.user-selected.read-write
                   key com.apple.security.network.client
                   key com.apple.security.personal-information.photos-library)" ;;
  *) echo "unknown variant $variant" >&2; exit 1 ;;
esac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 6 -o "$app/Contents/MacOS/CardImportProbe" "$here/main.swift"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>fr.michaelperrin.qaama.experiments.card-import.$variant</string>
	<key>CFBundleExecutable</key>
	<string>CardImportProbe</string>
	<key>CFBundleName</key>
	<string>CardImportProbe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

cat > "$entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$rights
</dict>
</plist>
EOF

codesign --force --sign - --entitlements "$entitlements" "$app"
echo "$app/Contents/MacOS/CardImportProbe"
