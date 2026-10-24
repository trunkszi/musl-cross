#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
for suite in test_config_and_patches test_scripts_contract test_upstream_sync test_release_workflow; do
    echo "=== ${suite} ==="
    bash "${ROOT}/tests/${suite}.sh"
done
echo 'All local contract tests: PASS'
