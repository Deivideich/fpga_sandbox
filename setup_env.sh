#!/usr/bin/env bash
# ==============================================================================
# AUTOMATED EDA ENVIRONMENT SETUP (OSS CAD Suite & OpenFPGA)
# ==============================================================================

setup_main() {
    local install_dir="${1:-$HOME/oss-cad-suite}"
    local suite_dir="$install_dir"
    local arch
    local os
    local attr_arch
    local ci_mode=false
    local script_dir
    local rules_source=""
    local udev_rules_dir
    local udev_rules_file
    local release_json
    local download_url
    local archive
    local staging_dir
    local extracted_dir
    local group

    arch=$(uname -m)
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

    if [ "${GITHUB_ACTIONS:-false}" = "true" ] || { [ -n "${CI:-}" ] && [ "${CI}" != "false" ]; }; then
        ci_mode=true
    fi

    printf '%s\n' "=========================================================="
    printf '%s\n' " Configuring EDA Environment (OSS CAD Suite & OpenFPGA)"
    printf '%s\n' "=========================================================="

    if [ "$EUID" -eq 0 ] && [ "$ci_mode" != true ]; then
        printf 'ERROR: Do not run this script as root or with sudo.\n' >&2
        printf 'The toolchain will install into your user space (%s).\n' "$install_dir" >&2
        return 1
    fi

    for command_name in curl tar grep cut head mktemp install; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf "ERROR: Required tool '%s' is missing.\n" "$command_name" >&2
            return 1
        fi
    done

    case "$arch" in
        x86_64) attr_arch="x64" ;;
        aarch64|arm64) attr_arch="arm64" ;;
        *)
            printf 'ERROR: Unsupported OSS CAD Suite architecture: %s\n' "$arch" >&2
            return 1
            ;;
    esac

    if [ "$os" != linux ]; then
        printf 'ERROR: OSS CAD Suite setup currently supports Linux, not %s.\n' "$os" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # 1. Hardware Access Configuration: udev Rules for OpenFPGALoader
    # --------------------------------------------------------------------------
    if [ "$ci_mode" = true ]; then
        printf '%s\n' "ℹ️  CI detected; skipping host udev and group configuration."
    else
        printf '%s\n' "🔌 Checking USB hardware permissions (udev rules)..."
        udev_rules_dir="${UDEV_RULES_DIR:-/etc/udev/rules.d}"
        udev_rules_file="$udev_rules_dir/99-openfpgaloader.rules"

        if [ ! -f "$udev_rules_file" ]; then
            for candidate in \
                "${OPENFPGALOADER_RULES_SOURCE:-}" \
                "$script_dir/99-openfpgaloader.rules" \
                "$script_dir/../openFPGALoader/99-openfpgaloader.rules"; do
                if [ -n "$candidate" ] && [ -f "$candidate" ]; then
                    rules_source="$candidate"
                    break
                fi
            done

            if [ -z "$rules_source" ]; then
                printf 'ERROR: 99-openfpgaloader.rules was not found beside the script or in ../openFPGALoader.\n' >&2
                return 1
            fi

            printf 'Installing udev rules from %s...\n' "$rules_source"
            if [ "$EUID" -eq 0 ]; then
                if ! install -D -m 0644 "$rules_source" "$udev_rules_file"; then
                    printf 'ERROR: Could not install udev rules at %s.\n' "$udev_rules_file" >&2
                    return 1
                fi
            else
                if ! command -v sudo >/dev/null 2>&1; then
                    printf 'ERROR: sudo is required to install udev rules at %s.\n' "$udev_rules_file" >&2
                    return 1
                fi
                if ! sudo install -D -m 0644 "$rules_source" "$udev_rules_file"; then
                    printf 'ERROR: Could not install udev rules at %s.\n' "$udev_rules_file" >&2
                    return 1
                fi
            fi

            if command -v udevadm >/dev/null 2>&1; then
                if [ "$EUID" -eq 0 ]; then
                    udevadm control --reload-rules && udevadm trigger || {
                        printf 'ERROR: Failed to reload udev rules.\n' >&2
                        return 1
                    }
                else
                    sudo udevadm control --reload-rules && sudo udevadm trigger || {
                        printf 'ERROR: Failed to reload udev rules.\n' >&2
                        return 1
                    }
                fi
            else
                printf 'WARNING: udevadm is unavailable; rules were copied but not reloaded.\n' >&2
            fi
            printf '%s\n' "✅ Udev rules installed."
        else
            printf 'ℹ️  Udev rules already exist at %s.\n' "$udev_rules_file"
        fi

        for group in plugdev dialout; do
            if command -v getent >/dev/null 2>&1 && getent group "$group" >/dev/null 2>&1; then
                if ! groups "${USER:-$(id -un)}" 2>/dev/null | grep -qE "(^|[[:space:]])${group}([[:space:]]|$)"; then
                    if ! command -v sudo >/dev/null 2>&1; then
                        printf "WARNING: sudo is unavailable; cannot add '%s' to group '%s'.\n" "${USER:-$(id -un)}" "$group" >&2
                        continue
                    fi
                    printf "Adding user '%s' to group '%s'...\n" "${USER:-$(id -un)}" "$group"
                    if ! sudo usermod -aG "$group" "${USER:-$(id -un)}"; then
                        printf "ERROR: Could not add user '%s' to group '%s'.\n" "${USER:-$(id -un)}" "$group" >&2
                        return 1
                    fi
                    printf 'WARNING: Log out and back in for group changes to take effect.\n' >&2
                fi
            fi
        done
    fi

    # --------------------------------------------------------------------------
    # 2. OSS CAD Suite Installation / Verification
    # --------------------------------------------------------------------------
    if [ ! -x "$suite_dir/bin/yosys" ] && [ -x "$suite_dir/oss-cad-suite/bin/yosys" ]; then
        suite_dir="$suite_dir/oss-cad-suite"
    fi

    if [ ! -x "$suite_dir/bin/yosys" ]; then
        printf '📦 Installing OSS CAD Suite into: %s...\n' "$install_dir"
        printf '🔍 Fetching latest stable release URL from GitHub API (%s)...\n' "$attr_arch"

        if ! release_json=$(curl -fsSL --retry 5 --retry-delay 3 \
            https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest); then
            printf 'ERROR: Failed to retrieve the latest OSS CAD Suite release.\n' >&2
            return 1
        fi

        download_url=$(printf '%s\n' "$release_json" \
            | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*linux-'"$attr_arch"'[^"]*"' \
            | head -n 1 \
            | cut -d '"' -f 4)
        if [ -z "$download_url" ]; then
            printf 'ERROR: No Linux %s asset was found in the latest release.\n' "$attr_arch" >&2
            return 1
        fi

        archive=$(mktemp "${TMPDIR:-/tmp}/oss-cad-suite.XXXXXX.tgz") || {
            printf 'ERROR: Could not create a temporary archive file.\n' >&2
            return 1
        }
        staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/oss-cad-suite.XXXXXX") || {
            rm -f -- "$archive"
            printf 'ERROR: Could not create a temporary extraction directory.\n' >&2
            return 1
        }

        printf '%s\n' "⬇️ Downloading latest release..."
        if ! curl -fL --retry 5 --retry-delay 3 "$download_url" -o "$archive"; then
            rm -f -- "$archive"
            rm -rf -- "$staging_dir"
            printf 'ERROR: OSS CAD Suite download failed.\n' >&2
            return 1
        fi

        printf '%s\n' "📦 Extracting files..."
        if ! tar -xzf "$archive" -C "$staging_dir"; then
            rm -f -- "$archive"
            rm -rf -- "$staging_dir"
            printf 'ERROR: Could not extract the OSS CAD Suite archive.\n' >&2
            return 1
        fi
        rm -f -- "$archive"

        if [ -x "$staging_dir/oss-cad-suite/bin/yosys" ]; then
            extracted_dir="$staging_dir/oss-cad-suite"
        elif [ -x "$staging_dir/bin/yosys" ]; then
            extracted_dir="$staging_dir"
        else
            rm -rf -- "$staging_dir"
            printf 'ERROR: The downloaded archive does not contain bin/yosys.\n' >&2
            return 1
        fi

        if [ -e "$install_dir" ]; then
            if [ -d "$install_dir" ] && [ -z "$(ls -A "$install_dir" 2>/dev/null)" ]; then
                rmdir -- "$install_dir" || {
                    rm -rf -- "$staging_dir"
                    printf 'ERROR: Could not prepare the installation directory %s.\n' "$install_dir" >&2
                    return 1
                }
            else
                rm -rf -- "$staging_dir"
                printf 'ERROR: %s exists but is not a valid OSS CAD Suite installation; move it aside before retrying.\n' "$install_dir" >&2
                return 1
            fi
        fi

        if ! mkdir -p -- "$(dirname -- "$install_dir")" || ! mv -- "$extracted_dir" "$install_dir"; then
            rm -rf -- "$staging_dir"
            printf 'ERROR: Could not install OSS CAD Suite at %s.\n' "$install_dir" >&2
            return 1
        fi
        rm -rf -- "$staging_dir"
        suite_dir="$install_dir"
        printf '%s\n' "✅ OSS CAD Suite installed successfully."
    else
        printf 'ℹ️  OSS CAD Suite is already installed at %s.\n' "$suite_dir"
    fi

    # --------------------------------------------------------------------------
    # 3. Environment Activation & CI Path Export
    # --------------------------------------------------------------------------
    printf '%s\n' "🚀 Activating toolchain execution environments..."
    if [ -f "$suite_dir/environment" ]; then
        if ! source "$suite_dir/environment"; then
            printf 'ERROR: Failed to source %s/environment.\n' "$suite_dir" >&2
            return 1
        fi
    else
        export PATH="$suite_dir/bin:$PATH"
    fi

    if [ -n "${GITHUB_PATH:-}" ]; then
        if ! printf '%s\n' "$suite_dir/bin" >> "$GITHUB_PATH"; then
            printf 'ERROR: Could not export the OSS CAD Suite path to GITHUB_PATH.\n' >&2
            return 1
        fi
    fi

    printf '%s\n' "=========================================================="
    printf '%s\n' "🎉 Setup complete! Loaded tool versions:"
    if ! yosys -V; then
        printf 'ERROR: Yosys is not available after environment activation.\n' >&2
        return 1
    fi
    if command -v openFPGALoader >/dev/null 2>&1; then
        openFPGALoader --version || {
            printf 'ERROR: Could not verify OpenFPGALoader.\n' >&2
            return 1
        }
    fi
    printf '%s\n' "=========================================================="
}

setup_main "$@"
setup_status=$?
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return "$setup_status"
fi
exit "$setup_status"
