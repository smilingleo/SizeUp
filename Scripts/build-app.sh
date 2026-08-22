#!/usr/bin/env bash
# Assembles ClipShot.app from the SwiftPM build product and ad-hoc signs it.
#
# The signing identifier is com.lliu.sizeup2 on purpose and must never change:
# macOS binds the Accessibility permission grant to the identifier, not to the
# name. The app is ClipShot; the identifier is an implementation detail.
# Without the fixed identifier, every rebuild would require re-approving the
# app in System Settings.
set -euo pipefail

CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.lliu.sizeup2"   # see comment above — the name is ClipShot, the identifier is not
APP_NAME="ClipShot"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/build/${APP_NAME}.app"

swift build -c "${CONFIG}" --package-path "${ROOT}"
BIN="$(swift build -c "${CONFIG}" --package-path "${ROOT}" --show-bin-path)/App"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
# The menu-bar icon; App loads it from the bundle's Resources at runtime.
cp "${ROOT}/Resources/statusbar_icon.png" "${APP}/Contents/Resources/statusbar_icon.png"

codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
codesign -dv "${APP}" 2>&1 | grep -E 'Identifier|Signature'

echo "Built ${APP}"
