#!/usr/bin/env bash
# End-to-end replay suite: regenerates the demo project and runs its XCUITests, which
# drive the app on a simulator against a mock ingest server inside the test runner.
#
#   scripts/e2e.sh                                   # whole suite
#   scripts/e2e.sh testTrackSendsCustomSessionEvent  # one test, by method name
#   scripts/e2e.sh -only-testing:ReplayDemoUITests/ReplayE2ETests/testTrackSendsCustomSessionEvent
#   DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' scripts/e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="$ROOT/Examples/ReplayDemo"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/maple-swift-dd-e2e}"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"

filters=()
for arg in "$@"; do
  case "$arg" in
    -only-testing:*|-skip-testing:*) filters+=("$arg") ;;
    test*) filters+=("-only-testing:ReplayDemoUITests/ReplayE2ETests/$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

(cd "$DEMO" && "$XCODEGEN" generate --quiet)

# Timestamped, because xcodebuild refuses to overwrite an existing result bundle.
RESULT="$DERIVED_DATA/e2e-$(date +%Y%m%d-%H%M%S).xcresult"

set +e
xcodebuild test \
  -project "$DEMO/ReplayDemo.xcodeproj" \
  -scheme ReplayDemo \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT" \
  ${filters[@]+"${filters[@]}"} 2>&1 \
  | grep -E --line-buffered "error:|warning: .*UITests|Test Case|Test Suite|Executed|TEST (SUCC|FAIL)|\*\* "
status=${PIPESTATUS[0]}
set -e

echo "result bundle: $RESULT"
exit "$status"
