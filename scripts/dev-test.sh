#!/bin/bash
# Local dev build/test gate. Upstream project ships empty signing settings (CI fills them)
# and an empty FineTuneUITests target that cannot load, so both are overridden here.
# Usage: [DERIVED_DATA=path] scripts/dev-test.sh [build|test]   (default: test)
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION="${1:-test}"
ARGS=(-scheme FineTune -configuration Debug -destination 'platform=macOS'
      CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R6GT8Z86AD "CODE_SIGN_IDENTITY=Apple Development")
# Set DERIVED_DATA to give parallel agents their own build dir (avoids xcodebuild lock contention).
[ -n "${DERIVED_DATA:-}" ] && ARGS+=(-derivedDataPath "$DERIVED_DATA")
[ "$ACTION" = test ] && ARGS+=(-only-testing:FineTuneTests)
xcodebuild "${ARGS[@]}" "$ACTION"
