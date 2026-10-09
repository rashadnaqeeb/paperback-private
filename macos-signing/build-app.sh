#!/bin/sh
# Builds the fork's Mac app, target/release/Paperback.app, signed for iCloud sync: Cargo's bundle
# with the bundle id, provisioning profile, identity, and entitlements Xcode set up for the
# stand-in app (see project.yml). The profile lasts a year; running this again renews it. Needs
# XcodeGen, and an Apple account signed in to Xcode.
set -eu
cd "$(dirname "$0")/.."
cargo build --release -p paperback
cargo build --release -p pb
xcodegen generate --quiet --spec macos-signing/project.yml --project macos-signing
xcodebuild -project macos-signing/PaperbackSigning.xcodeproj -scheme PaperbackSigning -configuration Debug \
	-derivedDataPath target/macos-signing -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
stand_in=target/macos-signing/Build/Products/Debug/PaperbackSigning.app
app=target/release/Paperback.app
cp target/release/paperback target/release/pb target/release/libpdfium.dylib "$app/Contents/MacOS/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.rashadnaqeeb.paperback.mac" "$app/Contents/Info.plist"
cp "$stand_in/Contents/embedded.provisionprofile" "$app/Contents/"
identity=$(codesign -dvv "$stand_in" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1)
codesign -d --entitlements - --xml "$stand_in" > target/macos-signing/entitlements.plist
codesign --force --sign "$identity" "$app/Contents/MacOS/libpdfium.dylib" "$app/Contents/MacOS/pb"
codesign --force --sign "$identity" --entitlements target/macos-signing/entitlements.plist "$app"
codesign --verify --deep --strict "$app"
echo "Built and signed $app"
