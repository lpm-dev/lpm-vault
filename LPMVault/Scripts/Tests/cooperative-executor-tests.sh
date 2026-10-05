#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd -- "$script_dir/../.." && pwd)"
unset LIBDISPATCH_COOPERATIVE_POOL_STRICT

runner_dir="$(mktemp -d)"
trap 'rm -rf -- "$runner_dir"' EXIT
swift_path="$(xcrun --find swift)"
helper_path="${swift_path%/bin/swift}/libexec/swift/pm/swiftpm-testing-helper"
xcrun clang -std=c11 -Wall -Wextra -Werror \
  "$script_dir/cooperative-test-runner.c" -o "$runner_dir/test-runner"
python3 - "$runner_dir" "$helper_path" <<'PY'
import json
import sys
from pathlib import Path

runner_dir = Path(sys.argv[1])
toolset = {
    "schemaVersion": "1.0.0",
    "testRunner": {
        "path": str(runner_dir / "test-runner"),
        "extraCLIOptions": [sys.argv[2]],
    },
}
(runner_dir / "toolset.json").write_text(json.dumps(toolset))
PY

SWIFT_TEST_TIME_LIMIT=60 \
  bash "$package_dir/Scripts/swift-test-watchdog.sh" \
  --package-path "$package_dir" --skip-build --disable-xctest --enable-swift-testing \
  --disable-automatic-resolution --toolset "$runner_dir/toolset.json" \
  --filter 'supersededWorkspaceSnapshotBuildStopsSerially|staleEnvironmentMutationPreservesCurrentSelection|navigationRejectsAStaleProjectLoad|cancelledDotenvExportDoesNotCommit|schemaRenameSerializesLaterMutations|queuedSchemaRenameRejectsChangedTarget'
