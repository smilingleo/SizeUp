#!/usr/bin/env bash
# Assembles Sizeup2.app from the SwiftPM build product and ad-hoc signs it.
#
# The signing identifier is fixed so that macOS keeps the Accessibility
# permission grant across rebuilds. Without this, every rebuild would require
# re-approving the app in System Settings.
set -euo pipefail

CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.lliu.sizeup2"
APP_NAME="Sizeup2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/build/${APP_NAME}.app"

swift build -c "${CONFIG}" --package-path "${ROOT}"
BIN="$(swift build -c "${CONFIG}" --package-path "${ROOT}" --show-bin-path)/App"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
codesign -dv "${APP}" 2>&1 | grep -E 'Identifier|Signature'

echo "Built ${APP}"
