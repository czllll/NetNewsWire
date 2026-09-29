#!/bin/bash
# Builds a Release NetNewsWire, signs it with your Apple Development certificate
# (a free Apple ID works — no provisioning profile needed), and installs it to
# ~/Applications/NetNewsWire-Translate.app.
#
# Without a provisioning profile the app can't use app groups, so the share and
# Safari extensions are signed but won't work. Everything else does.
#
# Usage: buildscripts/install_local.sh ["Apple Development: you@example.com (XXXXXXXXXX)"]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/NetNewsWire-local-build"
DESTINATION="${HOME}/Applications/NetNewsWire-Translate.app"

IDENTITY="${1:-$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}')}"
if [ -z "${IDENTITY}" ]; then
	echo "No Apple Development signing identity found. Sign in to Xcode with your Apple ID and create one in Settings > Accounts > Manage Certificates."
	exit 1
fi

echo "Building"
# The Release build's last script phase re-signs the share extension and fails without an identity; the app is complete by then.
xcodebuild -project "${PROJECT_ROOT}/NetNewsWire.xcodeproj" -scheme NetNewsWire -configuration Release \
	-destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "${BUILD_DIR}" \
	CODE_SIGNING_ALLOWED=NO build > "${BUILD_DIR}.log" 2>&1 || true
APP="${BUILD_DIR}/Build/Products/Release/NetNewsWire.app"
OTHER_FAILURES="$(sed -n '/The following build commands failed:/,/failure/p' "${BUILD_DIR}.log" | grep -vE 'build commands failed|Delete.{0,2}Unnecessary.{0,2}Frameworks|Building project|failure' || true)"
if [ -n "${OTHER_FAILURES}" ] || [ ! -d "${APP}" ]; then
	grep -E "error:" "${BUILD_DIR}.log" | sort -u | head -20 || true
	echo "Build failed. Log: ${BUILD_DIR}.log"
	exit 1
fi

APP_ENTITLEMENTS="$(mktemp)"
APPEX_ENTITLEMENTS="$(mktemp)"
cat > "${APP_ENTITLEMENTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><false/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PLIST
cat > "${APPEX_ENTITLEMENTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST

echo "Signing"
codesign --force --deep --sign "${IDENTITY}" "${APP}/Contents/Frameworks/Sparkle.framework"
for framework in "${APP}"/Contents/Frameworks/*.framework; do
	[ "$(basename "${framework}")" = "Sparkle.framework" ] || codesign --force --sign "${IDENTITY}" "${framework}"
done
for appex in "${APP}"/Contents/PlugIns/*.appex; do
	codesign --force --deep --sign "${IDENTITY}" --entitlements "${APPEX_ENTITLEMENTS}" "${appex}"
done
codesign --force --sign "${IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" "${APP}"
codesign --verify --deep --strict "${APP}"
rm -f "${APP_ENTITLEMENTS}" "${APPEX_ENTITLEMENTS}"

echo "Installing to ${DESTINATION}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${APP}/Contents/Info.plist")"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" > /dev/null 2>&1 || true
sleep 2
mkdir -p "$(dirname "${DESTINATION}")"
rm -rf "${DESTINATION}"
cp -R "${APP}" "${DESTINATION}"
open "${DESTINATION}"
echo "Done"
