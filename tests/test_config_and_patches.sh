#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "${ROOT}/targets/x86_64-unknown-linux-musl/versions"
[[ $(git -C "${ROOT}/builder" rev-parse HEAD) == "$CTNG_COMMIT" ]]
[[ -z $(git -C "${ROOT}/builder" status --porcelain) ]]
for component in GCC MUSL MOLD BINUTILS LINUX; do
    variable="EXPECTED_${component}_VERSION"
    package=${component,,}
    test -f "${ROOT}/builder/packages/${package}/${!variable}/chksum"
done
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git -C "${ROOT}/builder" archive "$CTNG_COMMIT" | tar -xf - -C "$work"
for patch_file in "${ROOT}/targets/x86_64-unknown-linux-musl/"*.patch; do
    patch --fuzz=0 --batch --dry-run -Np1 -d "$work" -i "$patch_file"
    patch --fuzz=0 --batch -Np1 -d "$work" -i "$patch_file"
done
echo 'Configuration and strict patch preflight: PASS'
