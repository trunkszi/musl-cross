# musl-cross

Contents: [Overview](#overview) · [Targets](#targets--component-matrix) ·
[Install](#install) · [Usage](#usage) · [Build](#build--automated-release) ·
[Layout](#repository-layout) · [License](#license)

## Overview

Prebuilt GCC cross-compilation toolchains for x86-64 Linux with musl libc.
Each archive contains C/C++ compilers, a target sysroot, binutils, and mold.
Choose a host variant compatible with the Linux machine running the compiler:
a musl target does not make the compiler itself universally static.
Windows, macOS, and other target architectures are not supplied.

## Targets & Component Matrix

| Target | Host suffix | GCC | musl | binutils | Linux headers | mold |
|---|---|---|---|---|---|---|
| x86_64-unknown-linux-musl | amazonlinux2 | 16.2.0 | 1.2.6 | 2.47 | 5.4.302 | 2.41.0 |
| x86_64-unknown-linux-musl | alinux3 | 16.2.0 | 1.2.6 | 2.47 | 5.4.302 | 2.41.0 |
| x86_64-unknown-linux-musl | centos7 | 16.2.0 | 1.2.6 | 2.47 | 5.4.302 | 2.41.0 |
| x86_64-unknown-linux-musl | ubuntu22 | 16.2.0 | 1.2.6 | 2.47 | 5.4.302 | 2.41.0 |

The accepted source and component expectations are recorded in
[`targets/x86_64-unknown-linux-musl/versions`](targets/x86_64-unknown-linux-musl/versions).
The table records the initial crosstool-NG 1.29.0 build baseline. Accepted metadata
and each release's receipts identify the actual source revision and versions.

## Install

Select one host suffix, download both files, and verify before extracting:

```sh
host=ubuntu22
archive="x86_64-unknown-linux-musl-${host}.tar.xz"
base=https://github.com/trunkszi/musl-cross/releases/download/v0.0.1
curl -fL --retry 3 -O "$base/$archive"
curl -fL --retry 3 -O "$base/$archive.sha256"
read -r digest < "$archive.sha256"
printf '%s  %s\n' "$digest" "$archive" | sha256sum --check -
tar -xJf "$archive"
export PATH="$PWD/x86_64-unknown-linux-musl/bin:$PATH"
```

`v0.0.1` is mutable. Pin the release's source SHA and artifact digest for
repeatable consumption. If replacement races your download, redownload both
files and verify again; never extract an archive with a mismatching digest.

## Usage

Compile static C/C++ executables, or dynamic programs using the target libraries:

```sh
target=x86_64-unknown-linux-musl
printf '#include <stdio.h>\nint main(void) { puts("hello"); }\n' > hello.c
printf '#include <iostream>\nint main() { std::cout << "hello\\n"; }\n' > hello.cc
"$target-gcc" -static hello.c -o hello-c
"$target-g++" -static hello.cc -o hello-cxx
"$target-gcc" hello.c -o hello-dynamic
"$target-g++" hello.cc -o hello-cxx-dynamic
sysroot=$("$target-gcc" -print-sysroot)
cxx_lib=$(dirname "$("$target-g++" -print-file-name=libstdc++.so.6)")
gcc_lib=$(dirname "$("$target-gcc" -print-file-name=libgcc_s.so.1)")
loader="$sysroot/lib/ld-musl-x86_64.so.1"
"$loader" ./hello-dynamic
"$loader" --library-path "$cxx_lib:$gcc_lib:$sysroot/lib" ./hello-cxx-dynamic
```

Use `-fuse-ld=mold` to select mold. Sanitizer checks use dynamic programs;
fully static sanitizer support is not implied.

For Rust, install its target standard library separately:

```sh
rustup target add x86_64-unknown-linux-musl
```

Set your Rust project's `.cargo/config.toml`:

```toml
[target.x86_64-unknown-linux-musl]
linker = "x86_64-unknown-linux-musl-gcc"
rustflags = ["-C", "target-feature=+crt-static"]
```

Run `cargo build --release --target x86_64-unknown-linux-musl`.
This retains Rust's bundled musl CRT handling; it does not force this archive's
musl version. `link-self-contained=no` requires a complete external Rust native
runtime set, including any required unwind library. Native C/C++ dependencies
must also use target-specific compiler, headers, and library paths.

## Build & Automated Release

```sh
git clone --recursive https://github.com/trunkszi/musl-cross.git
cd musl-cross
bash tests/run.sh
./scripts/build-with-docker.sh x86_64-unknown-linux-musl ubuntu:22.04 ubuntu22
# Alternatively, on a prepared disposable Linux host:
./scripts/make x86_64-unknown-linux-musl --skip-deps
```

Direct builds need a fresh `/opt/x-tools/<target>` prefix and may install host
prerequisites without `--skip-deps`. `BUILD_JOBS` defaults to 2.

CI checks the latest stable [crosstool-NG release](https://github.com/crosstool-ng/crosstool-ng/releases)
daily at 02:10 UTC. An updated release selects stable GCC, musl, and mold from
that exact catalog, preflights patches, and builds all four host variants.
Existing releases upload assets and notes before moving the tag, then `main`.
First releases stage a draft, upload assets/notes, promote refs, then publish.
On failure, recovery attempts draft cleanup and ref rollback; consult `publication.json`.
Accepted updates are written back as one Nathan Shea `first commit` root.
Manual dispatch supports ordinary builds, optional upstream checks, and
publication/reuse of a successful canonical run's complete artifact set.

Patch conflicts or build failures block publication and report old/new sources,
versions, failed stages, and repair instructions in Actions summaries.
Configure `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `NOTIFY_EMAIL_TO`
secrets for failure email; `SMTP_FROM` and the `SMTP_PORT` variable are optional.
Native GitHub email depends on the Owner/subscriber's notification settings.
Asset replacement is not atomic: publication failures may need manual recovery.

## Repository Layout

- `builder/`: pinned crosstool-NG submodule.
- `scripts/`: synchronization, dependency setup, build, verification, and release commands.
- `targets/`: target configuration, patches, and version expectations.
- `tests/`: offline behavioral contracts and strict patch checks.
- `.github/workflows/`: scheduled/manual build and release pipeline.

## License

No single top-level license is declared for these scripts and configuration.
GCC, musl, binutils, Linux headers, mold, and crosstool-NG retain their own
licenses. Review upstream terms and the archives' notices before redistribution.
