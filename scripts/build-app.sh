#!/usr/bin/env bash
# Builds build/AgentBalancerBar.app without Xcode: a release build, a hand-made bundle, an icon set
# drawn by the app binary and turned into an icns with iconutil, and an ad hoc signature.
set -euo pipefail

# The real path: the app refuses an output path that names a link, and a checkout opened through
# one would give it one.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

APP="build/AgentBalancerBar.app"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/Core/Version.swift | sed -n 1p)"
VERSION="${VERSION:-0.0.0}"

swift build -c release --product AgentBalancerBar
BIN="$(swift build -c release --product AgentBalancerBar --show-bin-path)/AgentBalancerBar"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/AgentBalancerBar"

# The app binary draws the icon sizes through the no-follow writer. It creates the folder itself.
"$BIN" --iconset "$ROOT/build/AppIcon.iconset"
iconutil -c icns "build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentBalancerBar</string>
  <key>CFBundleDisplayName</key><string>agent-balancer</string>
  <key>CFBundleIdentifier</key><string>app.agent-balancer.bar</string>
  <key>CFBundleExecutable</key><string>AgentBalancerBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# The app declares no scripting, URL, service, document or extension surface. Checked on the file
# written, so a bundle that declares one is never signed.
for key in NSAppleScriptEnabled OSAScriptingDefinition CFBundleURLTypes NSServices \
  CFBundleDocumentTypes NSUserActivityTypes NSExtension; do
  if plutil -extract "$key" xml1 -o /dev/null "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist declares $key, which the app must not have" >&2
    exit 1
  fi
done

codesign --force --sign - --timestamp=none "$APP"
codesign --verify "$APP"
echo "built $APP"
