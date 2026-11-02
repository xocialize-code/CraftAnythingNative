#!/bin/sh
# Build the app and assemble a development bundle at .build/CraftAnythingNative.app: the app, the
# builders' tool server and the native tools plugin side by side in Contents/MacOS, signed ad hoc.
#   Tools/make-app.sh [debug|release]   (default: debug)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-debug}
cd "$root"
swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)
app="$root/.build/CraftAnythingNative.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
for exe in CraftAnythingNative craft-anything-tool-server craft-anything-native-tools; do
    cp "$bin/$exe" "$app/Contents/MacOS/$exe"
done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.xocialize.CraftAnythingNative.dev</string>
<key>CFBundleName</key><string>CraftAnythingNative</string>
<key>CFBundleExecutable</key><string>CraftAnythingNative</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/craft-anything-tool-server" "$app/Contents/MacOS/craft-anything-native-tools"
codesign --force --sign - "$app"
echo "Built $app"
