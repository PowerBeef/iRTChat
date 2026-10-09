#!/bin/sh
# On-device test harness for iRTChat (physical iPhone only).
#
# Usage:
#   scripts/device-harness.sh [inference|ui|e4b|all] [extra xcodebuild args...]
#
#   inference  In-app scenarios through the real engine (download, load, text,
#              chat isolation, stop, tools, thinking, image, audio, settings
#              round-trip, context limit, benchmark). Downloads E2B if missing.
#   ui         Real-tap flows (send, Stop, Home button mid-reply, leave/return
#              mid-reply, rapid Settings changes, Models tab). Needs E2B downloaded.
#   e4b        Opt-in E4B scenarios (3.7 GB download).
#   calibrate  Context-size calibration: memory and speed at 4K-32K KV caches.
#   probes     LiteRT-LM feature probes (helper conversation, JSON, embeddings).
#   all        inference, then ui.
#
# Env: DEVICE_ID (default: deviceId from the git-ignored .mobilebuildmcp/config.yaml),
#      OUT (default: build/device-harness).
# Outputs: $OUT/<suite>.xcresult, $OUT/attachments/, $OUT/harness-report.json
set -eu

SUITE="${1:-all}"
[ $# -gt 0 ] && shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_CONFIG="$ROOT/.mobilebuildmcp/config.yaml"
if [ -z "${DEVICE_ID:-}" ] && [ -f "$LOCAL_CONFIG" ]; then
  DEVICE_ID="$(sed -n 's/^[[:space:]]*deviceId:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    "$LOCAL_CONFIG" | head -n 1)"
fi
case "${DEVICE_ID:-}" in
  "" | "<your-iphone-udid>")
    echo "No device. Set DEVICE_ID=<udid>, or copy .mobilebuildmcp/config.example.yaml" >&2
    echo "to .mobilebuildmcp/config.yaml and set deviceId (xcrun devicectl list devices)." >&2
    exit 2
    ;;
esac
OUT="${OUT:-$ROOT/build/device-harness}"
BUNDLE_ID="com.patricedery.irtchat"
mkdir -p "$OUT"
# Lets the in-app report survive crash relaunches within this run only.
export TEST_RUNNER_HARNESS_RUN_ID="run-$(date +%s)"

run_suite() {
  name="$1"
  shift
  result="$OUT/$name.xcresult"
  rm -rf "$result"
  echo "==> $name"
  set +e
  xcodebuild test \
    -project "$ROOT/iRTChat.xcodeproj" -scheme iRTChat -configuration Debug \
    -destination "id=$DEVICE_ID" -allowProvisioningUpdates \
    -resultBundlePath "$result" "$@"
  suite_status=$?
  set -e
  mkdir -p "$OUT/attachments/$name"
  xcrun xcresulttool export attachments --path "$result" \
    --output-path "$OUT/attachments/$name" >/dev/null 2>&1 || true
  return $suite_status
}

pull_report() {
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/harness-report.json --destination "$OUT/harness-report.json" \
    >/dev/null 2>&1 && echo "Report: $OUT/harness-report.json" || echo "No harness report on device"
}

status=0
case "$SUITE" in
  inference) run_suite inference -only-testing:iRTChatDeviceTests/InferenceScenarioTests "$@" || status=$? ;;
  ui) run_suite ui -only-testing:iRTChatUITests "$@" || status=$? ;;
  e4b) export TEST_RUNNER_HARNESS_E4B=1; run_suite e4b -only-testing:iRTChatDeviceTests/E4BScenarioTests "$@" || status=$? ;;
  probes)
    export TEST_RUNNER_HARNESS_PROBES=1
    run_suite probes -only-testing:iRTChatDeviceTests/ProbeScenarioTests "$@" || status=$?
    ;;
  calibrate)
    export TEST_RUNNER_HARNESS_CALIBRATE=1
    run_suite calibrate -only-testing:iRTChatDeviceTests/CalibrationScenarioTests "$@" || status=$?
    ;;
  all)
    run_suite inference -only-testing:iRTChatDeviceTests/InferenceScenarioTests "$@" || status=$?
    ui_status=0
    run_suite ui -only-testing:iRTChatUITests "$@" || ui_status=$?
    [ "$status" -eq 0 ] && status=$ui_status
    ;;
  *) echo "Unknown suite: $SUITE" >&2; exit 2 ;;
esac
pull_report
exit $status
