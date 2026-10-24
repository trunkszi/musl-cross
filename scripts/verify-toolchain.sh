#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <target> <toolchain-dir> <gcc-version> <musl-version> <loader-name> [mold-version]" >&2
    exit 64
}

[[ $# -eq 5 || $# -eq 6 ]] || usage

target=$1
[[ $target =~ ^[a-z0-9_]+(-[a-z0-9_]+)+$ && $5 =~ ^[A-Za-z0-9._-]+$ ]] || usage
toolchain_dir=$2
toolchain_dir=$(realpath -e -- "$toolchain_dir")
expected_gcc=$3
expected_musl=$4
loader_name=$5
expected_mold=${6:-${EXPECTED_MOLD_VERSION:-}}
if [[ -z $expected_mold ]]; then
    metadata="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/targets/${target}/versions"
    [[ ! -f $metadata ]] || expected_mold=$(sed -n 's/^EXPECTED_MOLD_VERSION=//p' "$metadata")
fi
cc="${toolchain_dir}/bin/${target}-gcc"
cxx="${toolchain_dir}/bin/${target}-g++"
mold="${toolchain_dir}/${target}/bin/ld.mold"
verify_cflags=(-Wall -Wextra -Werror)

[[ -x "${cc}" ]] || { echo "compiler not found: ${cc}" >&2; exit 1; }
[[ -x "${cxx}" ]] || { echo "C++ compiler not found: ${cxx}" >&2; exit 1; }
[[ -x "${mold}" ]] || { echo "mold linker not found: ${mold}" >&2; exit 1; }

for driver in "$cc" "$cxx" "$mold"; do
    resolved=$(realpath -e -- "$driver")
    [[ $resolved == "${toolchain_dir}/"* ]] || {
        echo "Compiler/linker escapes toolchain root: ${resolved}" >&2; exit 1;
    }
done

actual_gcc=$(timeout 30 "${cc}" -dumpfullversion)
[[ "${actual_gcc}" == "${expected_gcc}" ]] || {
    echo "GCC version mismatch: ${actual_gcc} != ${expected_gcc}" >&2
    exit 1
}

mold_output=$(timeout 30 "${mold}" --version)
[[ $mold_output == mold* ]] || { echo "Not a mold linker" >&2; exit 1; }
if [[ -n $expected_mold ]]; then
    actual_mold=$(awk '{print $2}' <<<"$mold_output")
    [[ $actual_mold == "$expected_mold" ]] || { echo "mold version mismatch: ${actual_mold} != ${expected_mold}" >&2; exit 1; }
fi

sysroot=$(timeout 30 "${cc}" -print-sysroot)
sysroot=$(realpath -e -- "$sysroot")
[[ $sysroot == "${toolchain_dir}/"* ]] || { echo "Sysroot escapes toolchain root: ${sysroot}" >&2; exit 1; }
loader="${sysroot}/lib/${loader_name}"
[[ -x "${loader}" ]] || { echo "musl loader not found: ${loader}" >&2; exit 1; }
loader=$(realpath -e -- "$loader")
[[ $loader == "${toolchain_dir}/"* ]] || { echo "Loader escapes toolchain root" >&2; exit 1; }
loader_status=0
loader_output=$(timeout 30 "${loader}" 2>&1) || loader_status=$?
[[ $loader_status != 124 && $loader_status != 137 ]] || { echo "musl loader timed out" >&2; exit 1; }
grep -Fxq "Version ${expected_musl}" <<<"${loader_output}" || {
    echo "musl version mismatch: ${loader_output}" >&2
    exit 1
}

verify_tmp=$(mktemp -d "${TMPDIR:-/tmp}/musl-cross-verify.XXXXXX")
cleanup() { rm -rf -- "${verify_tmp}" || true; }
trap cleanup EXIT

runtime_dirs=()
for directory in "${sysroot}/lib" "${sysroot}/usr/lib"; do
    [[ ! -d $directory ]] || runtime_dirs+=("$directory")
done
for runtime in libasan.so liblsan.so libubsan.so libtsan.so libgcc_s.so.1 \
               libgomp.so.1 libquadmath.so.0 libstdc++.so.6; do
    runtime_path=$(timeout 30 "${cc}" -print-file-name="${runtime}")
    [[ "${runtime_path}" != "${runtime}" && -f "${runtime_path}" ]] || {
        echo "target runtime not found: ${runtime}" >&2
        exit 1
    }
    runtime_path=$(realpath -e -- "$runtime_path")
    [[ $runtime_path == "${toolchain_dir}/"* ]] || {
        echo "Target runtime escapes toolchain root: ${runtime_path}" >&2; exit 1;
    }
    runtime_dirs+=("$(dirname "${runtime_path}")")
done
for directory in "${runtime_dirs[@]}"; do
    resolved=$(realpath -e -- "$directory")
    [[ $resolved == "$toolchain_dir" || $resolved == "${toolchain_dir}/"* ]] || { echo "Runtime directory escapes toolchain root: ${resolved}" >&2; exit 1; }
done
runtime_library_path=$(IFS=:; echo "${runtime_dirs[*]}")

run_dynamic() {
    timeout 30 "${loader}" --library-path "${runtime_library_path}" "$@"
}

expect_failure() {
    local name=$1 pattern=$2 program=$3 output status
    set +e
    output=$(run_dynamic "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 0 && ${status} -ne 124 && ${status} -ne 137 ]] || { echo "${name} did not produce a bounded expected failure (exit ${status})" >&2; exit 1; }
    grep -Eq "${pattern}" <<<"${output}" || {
        echo "${name} diagnostic missing: ${output}" >&2
        exit 1
    }
}

expect_tsan_failure() {
    local program=$1 output status
    local machine=${target%%-*}
    command -v setarch >/dev/null || {
        echo "setarch is required for the TSan no-ASLR runtime check" >&2
        exit 1
    }
    set +e
    output=$(timeout 30 setarch "${machine}" -R "${loader}" \
        --library-path "${runtime_library_path}" "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 0 && ${status} -ne 124 && ${status} -ne 137 ]] || { echo "TSan did not produce a bounded expected failure (exit ${status})" >&2; exit 1; }
    grep -Eq 'ThreadSanitizer: data race' <<<"${output}" || {
        echo "TSan diagnostic missing: ${output}" >&2
        exit 1
    }
}

cat >"${verify_tmp}/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("C PASS"); return 0; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -static "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-c"
[[ "$(timeout 30 "${verify_tmp}/hello-c")" == "C PASS" ]]

cat >"${verify_tmp}/hello.cc" <<'EOF'
#include <iostream>
int main() { std::cout << "C++ PASS\n"; }
EOF
timeout 30 "${cxx}" "${verify_cflags[@]}" -static "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx"
[[ "$(timeout 30 "${verify_tmp}/hello-cxx")" == "C++ PASS" ]]

timeout 30 "${cc}" "${verify_cflags[@]}" "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-dynamic")" == "C PASS" ]]
timeout 30 "${cxx}" "${verify_cflags[@]}" "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-cxx-dynamic")" == "C++ PASS" ]]

cat >"${verify_tmp}/iconv.c" <<'EOF'
#include <iconv.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    iconv_t cd = iconv_open("UTF-8", "GB18030");
    char input[] = { (char)0x90, 0x30, (char)0x81, 0x30 };
    const unsigned char expected[] = { 0xf0, 0x90, 0x80, 0x80 };
    char output[8] = {0}, *in_ptr = input, *out_ptr = output;
    size_t in_left = sizeof(input), out_left = sizeof(output);
    if (cd == (iconv_t)-1) return 1;
    alarm(5);
    if (iconv(cd, &in_ptr, &in_left, &out_ptr, &out_left) == (size_t)-1) return 2;
    alarm(0);
    iconv_close(cd);
    if (in_left || (size_t)(out_ptr-output) != sizeof(expected)) return 3;
    if (memcmp(output, expected, sizeof(expected))) return 4;
    puts("iconv PASS");
    return 0;
}
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" "${verify_tmp}/iconv.c" -o "${verify_tmp}/iconv"
[[ "$(run_dynamic "${verify_tmp}/iconv")" == "iconv PASS" ]]

cat >"${verify_tmp}/openmp.c" <<'EOF'
#include <omp.h>
#include <stdio.h>
int main(void) { int n = 0;
#pragma omp parallel reduction(+:n) num_threads(2)
n += 1; printf("%d\n", n); return n == 2 ? 0 : 1; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -fopenmp "${verify_tmp}/openmp.c" -o "${verify_tmp}/openmp"
[[ "$(run_dynamic "${verify_tmp}/openmp")" == 2 ]]

cat >"${verify_tmp}/quadmath.c" <<'EOF'
#include <quadmath.h>
#include <stdio.h>
int main(void) { char s[32]; quadmath_snprintf(s,sizeof s,"%.2Qf",(__float128)1.25); puts(s); }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" "${verify_tmp}/quadmath.c" -lquadmath -o "${verify_tmp}/quadmath"
[[ "$(run_dynamic "${verify_tmp}/quadmath")" == 1.25 ]]
timeout 30 "${cc}" "${verify_cflags[@]}" -static -fuse-ld=mold "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-mold"
[[ "$(timeout 30 "${verify_tmp}/hello-mold")" == "C PASS" ]]

cat >"${verify_tmp}/asan.c" <<'EOF'
#include <stdlib.h>
int main(void) { char *p=malloc(4); p[8]=1; return p[8]; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=address -fno-omit-frame-pointer "${verify_tmp}/asan.c" -o "${verify_tmp}/asan"
expect_failure ASan 'AddressSanitizer: heap-buffer-overflow' "${verify_tmp}/asan"

cat >"${verify_tmp}/ubsan.c" <<'EOF'
#include <limits.h>
int main(void) { volatile int v=INT_MAX; return v+1; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=undefined -fno-sanitize-recover=undefined "${verify_tmp}/ubsan.c" -o "${verify_tmp}/ubsan"
expect_failure UBSan 'runtime error|signed integer overflow' "${verify_tmp}/ubsan"

cat >"${verify_tmp}/lsan.c" <<'EOF'
#include <stdlib.h>
int main(void) {
    void *leaked = malloc(128);
    if (!leaked) return 1;
    ((volatile unsigned char *)leaked)[0] = 1;
    leaked = NULL;
    return leaked != NULL;
}
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=leak "${verify_tmp}/lsan.c" -o "${verify_tmp}/lsan"
expect_failure LSan 'detected memory leaks' "${verify_tmp}/lsan"

cat >"${verify_tmp}/tsan.c" <<'EOF'
#include <pthread.h>
static pthread_barrier_t gate;
static volatile int shared;
static void *write_shared(void *unused) {
    (void)unused;
    pthread_barrier_wait(&gate);
    for (int i = 0; i < 100000; ++i) shared++;
    return NULL;
}
int main(void) {
    pthread_t thread;
    if (pthread_barrier_init(&gate, NULL, 2) != 0) return 1;
    if (pthread_create(&thread, NULL, write_shared, NULL) != 0) return 2;
    pthread_barrier_wait(&gate);
    for (int i = 0; i < 100000; ++i) shared++;
    if (pthread_join(thread, NULL) != 0) return 3;
    pthread_barrier_destroy(&gate);
    return 0;
}
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=thread -pthread "${verify_tmp}/tsan.c" -o "${verify_tmp}/tsan"
expect_tsan_failure "${verify_tmp}/tsan"

echo "toolchain runtime verification: PASS"
