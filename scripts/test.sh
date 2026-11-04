#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
SUITE="${1:-all}"
if [[ $# -gt 1 ]]; then printf '%s\n' 'Usage: ./scripts/test.sh [suite]' >&2; exit 2; fi
if [[ "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'Tests require an Apple Silicon Mac running a native arm64 shell.' >&2
  exit 1
fi

IDENTITY=(Sources/ICS.swift Sources/SourceRegistry.swift Sources/SourceTask.swift)
LEGACY=(Sources/ICS.swift Sources/DailySchedule.swift Sources/Countdown.swift Sources/Course.swift Sources/RestartRestore.swift Sources/ReminderDestination.swift Sources/ReminderSync.swift)
NATIVE_WEB=("${IDENTITY[@]}" Sources/SourceDeadlineParser.swift Sources/MoTaskPayload.swift Sources/XzzdTaskPayload.swift Sources/NativeWebSession.swift Sources/NativeTaskCollector.swift Sources/NativePlatformAdapters.swift)
NATIVE_STATE=("${LEGACY[@]}" Sources/SourceRegistry.swift Sources/SourceTask.swift Sources/NativeSourceState.swift)
compile_run() {
  local name="$1"; shift
  xcrun swiftc "${FLAGS[@]}" "${APP_FRAMEWORKS[@]}" -o "$ROOT/build/$name-tests" "$@"
  "$ROOT/build/$name-tests"
}
run_suite() {
  case "$1" in
    core)
      compile_run core Sources/ICS.swift Sources/DailySchedule.swift Sources/Countdown.swift Sources/Course.swift Tests/CoreTests.swift
      for zone in UTC Asia/Shanghai America/Los_Angeles; do
        printf '%s\n' "Core regressions with host timezone: $zone"
        TZ="$zone" "$ROOT/build/core-tests"
      done
      ;;
    preview-clock) compile_run preview-clock Sources/PreviewClock.swift Tests/PreviewClockTests.swift ;;
    source-tasks) compile_run source-tasks "${IDENTITY[@]}" Tests/SourceTaskTests.swift ;;
    mo-payload) compile_run mo-payload "${IDENTITY[@]}" Sources/SourceDeadlineParser.swift Sources/MoTaskPayload.swift Tests/MoTaskPayloadTests.swift ;;
    xzzd-payload) compile_run xzzd-payload "${IDENTITY[@]}" Sources/SourceDeadlineParser.swift Sources/XzzdTaskPayload.swift Tests/XzzdTaskPayloadTests.swift ;;
    restart) compile_run restart "${LEGACY[@]}" Tests/RestartRestoreTests.swift ;;
    native-plan) compile_run native-plan "${IDENTITY[@]}" Sources/DailySchedule.swift Sources/Countdown.swift Sources/Course.swift Sources/NativeTaskSync.swift Tests/NativeTaskSyncTests.swift ;;
    native-state) compile_run native-state "${NATIVE_STATE[@]}" Tests/NativeStateTests.swift ;;
    native-controller) compile_run native-controller "${NATIVE_STATE[@]}" Sources/SourceDeadlineParser.swift Sources/NativeTaskSync.swift Sources/NativeSourceController.swift Tests/NativeControllerTests.swift ;;
    native-collector)
      xcrun swiftc "${FLAGS[@]}" "${APP_FRAMEWORKS[@]}" -o "$ROOT/build/native-collector-tests" "${NATIVE_WEB[@]}" Tests/NativeCollectorTests.swift
      NATIVE_SCRIPT_OUTPUT="$ROOT/build/native-web-script.js" "$ROOT/build/native-collector-tests"
      node Tests/NativeWebScriptTests.cjs build/native-web-script.js
      ;;
    native-authentication) compile_run native-authentication "${NATIVE_WEB[@]}" Tests/NativeAuthenticationChallengeTests.swift ;;
    native-navigation)
      python3 scripts/navigation-probe.py
      compile_run native-navigation "${IDENTITY[@]}" Sources/SourceDeadlineParser.swift Sources/MoTaskPayload.swift Sources/XzzdTaskPayload.swift Sources/NativeTaskCollector.swift Sources/NativePlatformAdapters.swift build/navigation-probe/NativeWebSessionProbe.swift
      ;;
    native-adapter) compile_run native-adapter "${NATIVE_WEB[@]}" Sources/NativeTaskSync.swift Sources/DailySchedule.swift Sources/Countdown.swift Sources/Course.swift Tests/NativeAdapterTests.swift ;;
    native-coordinator) compile_run native-coordinator "${LEGACY[@]}" Sources/AppSyncCoordinator.swift Tests/AppSyncCoordinatorTests.swift ;;
    native-writer) compile_run native-writer "${NATIVE_STATE[@]}" Sources/NativeTaskSync.swift Sources/AppSyncCoordinator.swift Sources/NativeReminderWriter.swift Tests/NativeReminderWriterTests.swift ;;
    destination) compile_run destination Sources/ReminderDestination.swift Sources/ReminderDestinationView.swift Tests/ReminderDestinationTests.swift ;;
    source-read-gate) compile_run source-read-gate Sources/SourceReadGate.swift Tests/SourceReadGateTests.swift ;;
    typecheck) xcrun swiftc "${FLAGS[@]}" -typecheck -parse-as-library "${APP_FRAMEWORKS[@]}" "${APP_SOURCES[@]}" ;;
    *)
      printf '%s\n' "Unknown suite: $1" 'Available: all core preview-clock source-tasks mo-payload xzzd-payload restart native-plan native-state native-controller native-collector native-authentication native-navigation native-adapter native-coordinator native-writer destination source-read-gate typecheck' >&2
      exit 2
      ;;
  esac
}
if [[ "$SUITE" == all ]]; then
  command -v node >/dev/null
  command -v python3 >/dev/null
  for suite in core preview-clock source-tasks mo-payload xzzd-payload restart native-plan native-state native-controller native-collector native-authentication native-navigation native-adapter native-coordinator native-writer destination source-read-gate typecheck; do
    printf '\n%s\n' "== $suite =="
    run_suite "$suite"
  done
else
  run_suite "$SUITE"
fi
