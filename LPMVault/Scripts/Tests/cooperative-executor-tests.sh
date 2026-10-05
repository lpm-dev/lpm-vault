#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd -- "$script_dir/../.." && pwd)"

LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 SWIFT_TEST_TIME_LIMIT=60 \
  bash "$package_dir/Scripts/swift-test-watchdog.sh" \
  --package-path "$package_dir" --skip-build \
  --filter 'supersededWorkspaceSnapshotBuildStopsSerially|staleEnvironmentMutationPreservesCurrentSelection|navigationRejectsAStaleProjectLoad|cancelledDotenvExportDoesNotCommit'
