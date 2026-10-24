#!/usr/bin/env bash
# Functions are inert until install_dependencies is called by the build driver.

setup_alinux_repositories() {
    local section component
    local repository_file="${BUILD_WORK_DIR}/alinux3.repo"
    : > "$repository_file"
    for section in os updates module plus powertools; do
        component="alinux/\$releasever/${section}/\$basearch"
        # Keep the yum architecture placeholder literal.
        # shellcheck disable=SC2016
        [[ $section != module ]] || component='alinux/3/module/$basearch'
        cat >> "$repository_file" <<REPO
[alinux3-${section}]
name=Alibaba Cloud Linux 3 - ${section}
baseurl=https://mirrors.aliyun.com/${component}/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3
REPO
    done
    ${SUDO[@]+"${SUDO[@]}"} mkdir -p /etc/yum.repos.d/musl-cross-backup
    local files=(/etc/yum.repos.d/*.repo)
    if [[ -e ${files[0]} ]]; then
        ${SUDO[@]+"${SUDO[@]}"} mv -- "${files[@]}" /etc/yum.repos.d/musl-cross-backup/
    fi
    ${SUDO[@]+"${SUDO[@]}"} cp -- "$repository_file" /etc/yum.repos.d/alinux3.repo
    timeout 120 ${SUDO[@]+"${SUDO[@]}"} "$PKG_MANAGER" clean all
}

setup_centos_repositories() {
    # Preserve yum placeholders while changing the repository base URL.
    # shellcheck disable=SC2016
    ${SUDO[@]+"${SUDO[@]}"} sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
        -e 's|^#baseurl=http://mirror.centos.org/centos/$releasever|baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009|' \
        -e 's|^baseurl=https\?://vault.centos.org/7.9.2009|baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009|' \
        /etc/yum.repos.d/CentOS-*.repo
    timeout 120 ${SUDO[@]+"${SUDO[@]}"} yum clean all
    timeout 180 ${SUDO[@]+"${SUDO[@]}"} yum makecache
    timeout 180 ${SUDO[@]+"${SUDO[@]}"} yum install -y epel-release centos-release-scl centos-release-scl-rh
    local flavor repository_file repository_name
    for flavor in rh sclo; do
        repository_file="${BUILD_WORK_DIR}/scl-${flavor}.repo"
        cat > "$repository_file" <<REPO
[centos-sclo-${flavor}]
name=CentOS 7 SCL ${flavor}
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/\$basearch/${flavor}/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-SIG-SCLo
REPO
        repository_name=scl
        [[ $flavor != rh ]] || repository_name=scl-rh
        ${SUDO[@]+"${SUDO[@]}"} cp -- "$repository_file" "/etc/yum.repos.d/CentOS-SCLo-${repository_name}.repo"
    done
    timeout 120 ${SUDO[@]+"${SUDO[@]}"} yum clean all
    timeout 180 ${SUDO[@]+"${SUDO[@]}"} yum makecache
}

setup_pip_cmake() {
    [[ $USE_PIP_CMAKE == true ]] || return 0
    # Keep Python 3.6-compatible tools private instead of replacing the host pip.
    # Bootstrap pip recognizes manylinux2014 wheels; never build CMake from source.
    python3 -m pip install --disable-pip-version-check --target "${BUILD_WORK_DIR}/bootstrap-python" 'pip==21.3.1'
    PYTHONPATH="${BUILD_WORK_DIR}/bootstrap-python" python3 -m pip install --disable-pip-version-check --only-binary=:all: \
        --target "${BUILD_WORK_DIR}/host-tools" 'cmake==3.28.4'
    export PYTHONPATH="${BUILD_WORK_DIR}/host-tools${PYTHONPATH:+:${PYTHONPATH}}"
    export PATH="${BUILD_WORK_DIR}/host-tools/bin:${PATH}"
}

activate_gcc10() {
    mkdir -p "${BUILD_WORK_DIR}/host-bin"
    local name
    for name in gcc g++ cpp c++; do
        [[ -x /usr/bin/gcc10-${name} ]] || { echo "Missing host compiler: gcc10-${name}" >&2; return 1; }
        ln -s "/usr/bin/gcc10-${name}" "${BUILD_WORK_DIR}/host-bin/${name}"
    done
    export PATH="${BUILD_WORK_DIR}/host-bin:${PATH}"
}

activate_devtoolset() {
    export PATH="/opt/rh/devtoolset-11/root/usr/bin:${PATH}"
    command -v gcc >/dev/null
}

detect_host() {
    local ID='' VERSION_ID='' ID_LIKE=''
    [[ ! -f /etc/os-release ]] || source /etc/os-release
    case "$ID:$VERSION_ID" in
        ubuntu:22.04) echo ubuntu22 ;;
        ubuntu:*|debian:*|linuxmint:*) echo debian ;;
        alinux:3*) echo alinux3 ;;
        amzn:2) echo amazonlinux2 ;;
        amzn:2023|rhel:*|fedora:*|rocky:*|almalinux:*|alinux:*) echo rhel ;;
        centos:7*) echo centos7 ;;
        centos:*) echo rhel ;;
        arch:*|manjaro:*) echo arch ;;
        alpine:*) echo alpine ;;
        *) echo "Unsupported host: ${ID}:${VERSION_ID}" >&2; return 1 ;;
    esac
}

update_packages() {
    local status=0
    case "$PKG_MANAGER" in
        dnf|yum)
            # Fresh DNF repositories can download hundreds of MB of metadata.
            timeout 900 ${SUDO[@]+"${SUDO[@]}"} "$PKG_MANAGER" check-update || status=$?
            [[ $status == 0 || $status == 100 ]] || {
                echo "Package metadata update failed (${PKG_MANAGER}, exit ${status})" >&2
                return "$status"
            } ;;
        apt-get) timeout 180 ${SUDO[@]+"${SUDO[@]}"} apt-get update ;;
        apk) timeout 180 ${SUDO[@]+"${SUDO[@]}"} apk update ;;
        pacman) timeout 180 ${SUDO[@]+"${SUDO[@]}"} pacman -Sy --noconfirm ;;
    esac
}

install_dependencies() {
    local profile manager found=false step attempt status=0
    profile=$(detect_host)
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/packages/${profile}.conf"
    for manager in "${PACKAGE_MANAGERS[@]}"; do
        if command -v "$manager" >/dev/null; then
            PKG_MANAGER=$manager
            found=true
            break
        fi
    done
    [[ $found == true ]] || { echo "No supported package manager for ${profile}" >&2; return 1; }
    for step in ${MIRROR_SETUP_COMMANDS[@]+"${MIRROR_SETUP_COMMANDS[@]}"}; do "$step"; done
    update_packages
    local install_args=()
    case "$PKG_MANAGER" in
        dnf|yum) install_args=(install -y) ;;
        apt-get) export DEBIAN_FRONTEND=noninteractive; install_args=(install -y --no-install-recommends) ;;
        apk) install_args=(add --no-cache) ;;
        pacman) install_args=(-S --needed --noconfirm) ;;
    esac
    for attempt in 1 2 3; do
        if timeout 1800 ${SUDO[@]+"${SUDO[@]}"} "$PKG_MANAGER" "${install_args[@]}" "${PACKAGES[@]}"; then
            status=0
            break
        else
            status=$?
        fi
        if [[ $attempt != 3 ]]; then sleep 10; fi
    done
    [[ $status == 0 ]] || { echo "Dependency installation failed after 3 attempts" >&2; return "$status"; }
    for step in "${EXTRA_SETUP_COMMANDS[@]}"; do "$step"; done
    cmake --version
    gcc --version
}
