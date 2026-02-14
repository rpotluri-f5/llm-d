#!/bin/bash
# shared package management utilities for multi-os support
#
# Required environment variables:
# - CUDA_MAJOR: CUDA major version (e.g., 12)
# - CUDA_MINOR: CUDA minor version (e.g., 9)
# - PYTHON_VERSION: Python version (e.g., 3.12)
# Optional docker secret mounts:
# - /run/secrets/subman_org: Subscription Manager Organization - used if on a ubi based image for entitlement
# - /run/secrets/subman_activation_key: Subscription Manager Activation key - used if on a ubi based image for entitlement

# Assumes rhel check in consuming script
ensure_registered() {
  install -d -m0755 /etc/pki/consumer /etc/pki/entitlement /etc/rhsm
  subscription-manager clean || true
  if [ ! -f /etc/pki/consumer/cert.pem ]; then
    test -f /run/secrets/subman_org && test -f /run/secrets/subman_activation_key
    subscription-manager register \
      --org "$(cat /run/secrets/subman_org)" \
      --activationkey "$(cat /run/secrets/subman_activation_key)" \
      --force
    subscription-manager refresh || true
  fi
}

# Assumes rhel check in consuming script
ensure_unregistered() {
  echo "beginning un-registration process"
  if [ -f /etc/pki/consumer/cert.pem ]; then
    subscription-manager unregister || true
  fi
  subscription-manager clean || true
  rm -rf /etc/pki/entitlement/* /etc/pki/consumer/* /etc/rhsm/* /var/cache/dnf/* || true
}

# detect architecture for repo URLs
get_download_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        amd64|x86_64)
            echo "x86_64"
            ;;
        aarch64)
            echo "aarch64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac
}

# expand environment variables in yaml string
expand_vars() {
    local yaml="$1"
    echo "$yaml" | sed "s/\${PYTHON_VERSION}/${PYTHON_VERSION}/g; \
                        s/\${CUDA_MAJOR}/${CUDA_MAJOR}/g; \
                        s/\${CUDA_MINOR}/${CUDA_MINOR}/g"
}

# find package mappings file (script dir or /tmp)
find_mappings_file() {
    local filename="$1"
    local script_dir="$2"

    if [ -f "${script_dir}/${filename}" ]; then
        echo "${script_dir}/${filename}"
    elif [ -f "/tmp/${filename}" ]; then
        echo "/tmp/${filename}"
    else
        echo "ERROR: ${filename} not found" >&2
        exit 1
    fi
}

# setup ubuntu repos
setup_ubuntu_repos() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update -qq
    # efa uses apt for installing packages rather than apt-get
    apt update -qq
}

# setup rhel repos (EPEL and CUDA)
setup_rhel_repos() {
    local download_arch="$1"

    dnf -q install -y dnf-plugins-core
    dnf -q install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
    dnf config-manager --set-enabled epel
    dnf config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/${download_arch}/cuda-rhel9.repo"
}

# update system packages
update_system() {
    local os="$1"

    if [ "$os" = "ubuntu" ]; then
        apt-get update -qq
        apt-get upgrade -y
    elif [ "$os" = "rhel" ]; then
        dnf -q update -y
    fi
}

# install packages
install_packages() {
    local os="$1"
    shift
    local packages=("$@")

    if [ "$os" = "ubuntu" ]; then
        apt-get install -y --no-install-recommends "${packages[@]}"
    elif [ "$os" = "rhel" ]; then
        dnf -q install -y --allowerasing "${packages[@]}"
    fi
}

# cleanup package manager cache
cleanup_packages() {
    local os="$1"

    if [ "$os" = "ubuntu" ]; then
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    elif [ "$os" = "rhel" ]; then
        dnf clean all
    fi
}

# autoremove unused packages
autoremove_packages() {
    local os="$1"

    if [ "$os" = "ubuntu" ]; then
        apt-get autoremove -y
    elif [ "$os" = "rhel" ]; then
        dnf autoremove -y
    fi
}

# install yq binary (mikefarah/yq) for yaml parsing
# uses the OS package manager to bootstrap wget, then downloads the yq binary
install_yq() {
    local os="$1"
    local yq_version="v4.44.1"
    local yq_arch
    yq_arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

    # bootstrap wget if not available (base images may not include it)
    if ! command -v wget > /dev/null 2>&1; then
        if [ "$os" = "ubuntu" ]; then
            apt-get update -qq
            apt-get install -y wget
        elif [ "$os" = "rhel" ]; then
            dnf -q install -y wget
        fi
    fi

    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_${yq_arch}"
    chmod +x /usr/local/bin/yq
}

# load package list from yaml mappings
# usage: load_packages_from_yaml <os> <manifest_yaml> <section_key>
# returns: array of package names for the target os
load_packages_from_yaml() {
    local os="$1"
    local manifest="$2"
    local section="${3:-rhel_to_ubuntu}"

    local packages=()

    if [ "$os" = "ubuntu" ]; then
        # get ubuntu packages from mappings (skip null values)
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(echo "$manifest" | yq -r ".${section} | to_entries | .[] | select(.value | . == null | not) | .value")

        # add ubuntu-only packages if they exist
        if echo "$manifest" | yq -e '.ubuntu_only' > /dev/null 2>&1; then
            while IFS= read -r pkg; do
                [ -n "$pkg" ] && packages+=("$pkg")
            done < <(echo "$manifest" | yq -r '.ubuntu_only[]')
        fi
    elif [ "$os" = "rhel" ]; then
        # use rhel package names directly from yaml keys
        while IFS= read -r pkg; do
            packages+=("$pkg")
        done < <(echo "$manifest" | yq -r ".${section} | keys | .[]")
    fi

    printf '%s\n' "${packages[@]}"
}

# load packages from yaml file with variable expansion
# usage: load_and_expand_packages <os> <mappings_file>
# returns: package names (one per line) for the target os
load_and_expand_packages() {
    local os="$1"
    local mappings_file="$2"

    local manifest manifest_expanded
    manifest=$(cat "$mappings_file")
    manifest_expanded=$(expand_vars "$manifest")

    load_packages_from_yaml "$os" "$manifest_expanded"
}

# merge two yaml package manifests (accelerator overrides common)
# usage: merge_package_manifests <common_yaml> <accelerator_yaml>
# returns: merged yaml manifest
merge_package_manifests() {
    local common="$1"
    local accelerator="$2"

    # use yq to deeply merge the two manifests
    # accelerator packages override common ones with same key
    yq eval-all 'select(fi == 0) * select(fi == 1)' <(echo "$common") <(echo "$accelerator")
}

# load and merge packages from common + accelerator-specific locations
# usage: load_layered_packages <os> <package_type> <accelerator>
# package_type: "builder-packages.yaml" or "runtime-packages.yaml"
# accelerator: "cuda", "xpu", "hpu", etc.
# returns: package names (one per line) for the target os
# if no accelerator is passed only the common manifests will be used
# supports three scenarios:
#   1. both common and accelerator files exist - merge them (accelerator overrides common)
#   2. only common file exists - use it
#   3. only accelerator file exists - use it
load_layered_packages() {
    local os="$1"
    local package_type="$2"
    local accelerator="$3"

    local common_file="/tmp/packages/common/${package_type}"
    local accelerator_file="/tmp/packages/${accelerator}/${package_type}"

    # check if at least one file exists
    if [ ! -f "$common_file" ] && [ ! -f "$accelerator_file" ]; then
        echo "ERROR: No package file found at $common_file or $accelerator_file" >&2
        exit 1
    fi

    local merged_manifest

    # scenario 1: both files exist - merge them
    if [ -f "$common_file" ] && [ -f "$accelerator_file" ]; then
        local common_manifest common_expanded
        common_manifest=$(cat "$common_file")
        common_expanded=$(expand_vars "$common_manifest")

        local accel_manifest accel_expanded
        accel_manifest=$(cat "$accelerator_file")
        accel_expanded=$(expand_vars "$accel_manifest")

        merged_manifest=$(merge_package_manifests "$common_expanded" "$accel_expanded")

    # scenario 2: only common file exists
    elif [ -f "$common_file" ]; then
        local common_manifest
        common_manifest=$(cat "$common_file")
        merged_manifest=$(expand_vars "$common_manifest")

    # scenario 3: only accelerator file exists
    else
        local accel_manifest
        accel_manifest=$(cat "$accelerator_file")
        merged_manifest=$(expand_vars "$accel_manifest")
    fi

    # extract package list for target OS
    load_packages_from_yaml "$os" "$merged_manifest"
}
