#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${ROOT_DIR}/build/HarborDerivedData"
APP_NAME="Harbor"
APP_BUNDLE="${DERIVED_DATA_DIR}/Build/Products/Debug/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
SUPPORT_DIR="${TMPDIR:-/tmp}/HarborBuildApplicationSupport"

pkill -x "${APP_NAME}" >/dev/null 2>&1 || true

xcodebuild build \
  -project "${ROOT_DIR}/Harbor.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  CODE_SIGNING_ALLOWED=NO

launch_app() {
  /usr/bin/open -n "${APP_BUNDLE}" --args \
    --harbor-application-support-directory "${SUPPORT_DIR}"
}

case "${MODE}" in
  run)
    launch_app
    ;;
  --debug|debug)
    lldb -- "${APP_BINARY}" \
      --harbor-application-support-directory "${SUPPORT_DIR}"
    ;;
  --logs|logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate 'process == "Harbor"'
    ;;
  --telemetry|telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "co.hapy.harbor"'
    ;;
  --verify|verify)
    launch_app
    sleep 1
    pgrep -x "${APP_NAME}" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
