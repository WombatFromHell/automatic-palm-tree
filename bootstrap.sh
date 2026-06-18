#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory (the flake root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# remote host used by pull, first_stage, and second_stage
PULL_REMOTE="nxxel@192.168.1.153"
PULL_REMOTE_PORT="2222"
PULL_REMOTE_IDENTITY="~/.ssh/id_rsa"
PULL_REMOTE_SOURCE="~/Projects/nix/"
#
SSHFS_REMOTE="nxxel@192.168.1.153:/share/homes/nxxel"
SSHFS_MNTDIR="$HOME/.nas-home"
#
SSHFS_REMOTE_BASEDIR="$SSHFS_MNTDIR/Projects/silver-octo-bassoon/files/support"
SSHFS_SSHDIR="$SSHFS_REMOTE_BASEDIR/.ssh"
SSHFS_GPGDIR="$SSHFS_REMOTE_BASEDIR/.ssh/gnupg-keys"
#
SSH_DIR="$HOME/.ssh"

# stage 2 bootstrap
RSYNC_BASECMD=(rsync -rvh --update --delete)
#
STAGE2_ANSIBLE_ROOT="$SSHFS_MNTDIR/Projects/silver-octo-bassoon/"
ANSIBLE_ROOT="$HOME/.ansible-root"
#
NH_FLAKE_ROOT="$HOME/.config/flakeroot"
DOTFILES_DIR="$HOME/.config/dotfiles"

first_stage() {
    for cmd in sshfs fusermount rsync; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: '$cmd' is not installed or not on PATH." >&2
            return 1
        fi
    done

    mkdir -p "$SSHFS_MNTDIR"
    for dir in "$HOME/.gnupg" "$HOME/.ssh"; do
        if [ -d "$dir" ]; then
            chmod 0700 "$dir"
        else
            mkdir -p "$dir"
            chmod 0700 "$dir"
        fi
    done

    # Bail if the mountpoint is already active (e.g. nasmount-sshfs service
    # deployed by a previous 'init' has it mounted).  In that case the remote
    # files are already accessible, so we just skip the sshfs call and proceed
    # straight to copying keys / importing GPG keys.
    if mountpoint -q "$SSHFS_MNTDIR"; then
        echo "$SSHFS_MNTDIR is already mounted — skipping sshfs mount step."
    else
        echo "Mounting sshfs remote..."
        local sshfs_opts=(-p "${PULL_REMOTE_PORT}")
        if [ -n "$PULL_REMOTE_IDENTITY" ]; then
            sshfs_opts+=(-o "IdentityFile=$PULL_REMOTE_IDENTITY")
        fi
        if ! sshfs "${sshfs_opts[@]}" "$SSHFS_REMOTE" "$SSHFS_MNTDIR"; then
            echo "Error: something went wrong when mounting the sshfs remote!"
            return 1
        fi
    fi

    for key in id_rsa id_rsa.pub; do
        src="$SSHFS_SSHDIR/$key"
        if [ -f "$src" ]; then
            echo "Copying $key..."
            cp -f "$src" "$SSH_DIR/$key"
            chmod 0600 "$SSH_DIR/$key"
        else
            echo "WARN: key '$src' not found, skipping." >&2
        fi
    done

    for key in public-key.asc private-key.asc; do
        src="$SSHFS_GPGDIR/$key"
        if [ -f "$src" ]; then
            echo "Importing gnupg key: $key..."
            gpg --import "$src"
        else
            echo "WARN: key '$src' not found, skipping." >&2
        fi
    done

    echo "First stage bootstrap complete!"
    return 0
}

second_stage() {
    if ! "${RSYNC_BASECMD[@]}" "$STAGE2_ANSIBLE_ROOT" "$ANSIBLE_ROOT"/; then
        echo "Error: something went wrong when rsync'ing '$ANSIBLE_ROOT'!"
        return 1
    fi

    ln -sfT "$ANSIBLE_ROOT/files/dotfiles" "$DOTFILES_DIR"

    echo "Second stage bootstrap complete!"
    return 0
}

cmd_prepare_swap() {
    # Skip if swapfile already exists (from a previous preparation or manual setup)
    if [ -f /var/lib/swapfile ]; then
        echo "Swapfile at /var/lib/swapfile already exists - skipping swap preparation."
        return 0
    fi

    local swap_module="/etc/nixos/swap-prepare.nix"
    local config_file="/etc/nixos/configuration.nix"
    local source_module="$SCRIPT_DIR/modules/bootstrap.nix"

    local maybe_sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        maybe_sudo="sudo"
    fi

    if [ ! -d /etc/nixos ]; then
        echo "WARN: /etc/nixos does not exist - cannot prepare swapfile." >&2
        return 0
    fi

    if [ ! -f "$source_module" ]; then
        echo "WARN: source module '$source_module' not found - cannot prepare swapfile." >&2
        return 0
    fi

    # Copy the bootstrap swap + zswap module from the flake (uses boot.kernelParams
    # instead of boot.zswap.* so it works on any NixOS release)
    $maybe_sudo cp -f "$source_module" "$swap_module"

    # Inject into imports list if not already present.
    # Handles both inline (imports = [) and split-line (imports =\n  [) formats.
    if ! grep -q "swap-prepare" "$config_file" 2>/dev/null; then
        sed -i '/imports\s*=/{:a;/\[/!{N;ba};s/\[/[\n    .\/swap-prepare.nix/}' "$config_file"
    fi

    echo "Building swapfile + zswap config to avoid OOM during subsequent rebuild..."
    if ! $maybe_sudo env NIX_CONFIG="$NIX_CONFIG" nixos-rebuild switch; then
        echo "WARN: swap preparation failed - continuing anyway." >&2
    else
        echo "============================================"
        echo "  Swapfile and zswap are now configured."
        echo "  REBOOT your machine, then run:"
        echo "    ./bootstrap.sh init"
        echo "  to perform the real rebuild."
        echo "============================================"
        exit 0
    fi
}

cmd_init() {
    local target="${1:-}"
    local use_nh="${2:-false}"
    local flake="${NH_FLAKE_ROOT:-$SCRIPT_DIR}"

    export NIX_CONFIG="extra-experimental-features = nix-command flakes"

    local mode
    local flake_ref="$flake"

    if [ -n "$target" ]; then
        # Explicit target provided
        if [[ "$target" == *@* ]]; then
            mode="home"
            flake_ref="${flake}#${target}"
            echo "Building home configuration for '${target}'..."
        else
            mode="os"
            flake_ref="${flake}#${target}"
            echo "Building system configuration for '${target}'..."
        fi
    else
        # Auto-detect mode from /etc/os-release
        local os_name
        os_name=$(
            grep -oP '(?<=^NAME=")[^"]+' /etc/os-release 2>/dev/null ||
                grep -oP '(?<=^NAME=)\S+' /etc/os-release 2>/dev/null ||
                echo "unknown"
        )

        if [ "$os_name" = "NixOS" ]; then
            mode="os"
            echo "Detected NixOS - running system switch..."
        else
            mode="home"
            echo "Detected ${os_name} - running home switch..."
        fi
    fi

    # Ensure home-manager is initialized for home-mode (needed by both nh and non-nh paths)
    if [ "$mode" = "home" ] && {
        ! command -v home-manager &>/dev/null ||
            [ ! -f "$HOME/.config/home-manager/flake.nix" ]
    }; then
        echo "Home Manager not yet initialized - running init..."
        nix run "github:nix-community/home-manager/master" -- init --switch
    fi

    # Ensure a swapfile exists before running a full system rebuild
    if [ "$mode" = "os" ]; then
        cmd_prepare_swap
    fi

    if [ "$use_nh" = "true" ]; then
        local nh_cmd=(
            env NH_FLAKE_ROOT="$NH_FLAKE_ROOT"
            nix run "github:NixOS/nixpkgs/nixos-26.05#nh" --
        )

        if [ "$mode" = "os" ]; then
            echo "Running 'nh os switch'..."
            "${nh_cmd[@]}" os switch "$flake_ref" -- -L
        else
            echo "Running 'nh home switch'..."
            "${nh_cmd[@]}" home switch "$flake_ref" -- -L
        fi
    else
        local cmd=(nix develop "$flake" -c)

        if [ "$mode" = "os" ]; then
            cmd+=(sudo nixos-rebuild switch --flake "$flake_ref" -L)
        else
            cmd+=(home-manager switch -L --flake "$flake_ref")
        fi

        echo "Running inside flake dev shell..."
        "${cmd[@]}"
    fi
}

cmd_bootstrap() {
    first_stage
    second_stage
}

cmd_clean() {
    echo "Running 'nh clean all'..."
    local cmd=(
        env NIX_CONFIG="extra-experimental-features = nix-command flakes" "NH_FLAKE_ROOT=$NH_FLAKE_ROOT"
        nix run "github:NixOS/nixpkgs/nixos-26.05#nh" --
        clean all
    )
    "${cmd[@]}" "$@"
}

# Build the SSH options string for rsync/ssh commands.
# Usage:  _ssh_opts
# Prints "-p PORT" and, if PULL_REMOTE_IDENTITY is set, appends "-i PATH".
_ssh_opts() {
    local opts="-p ${PULL_REMOTE_PORT}"
    if [ -n "$PULL_REMOTE_IDENTITY" ]; then
        opts="${opts} -i ${PULL_REMOTE_IDENTITY}"
    fi
    printf '%s' "$opts"
}

cmd_pull() {
    local target="${1:-$NH_FLAKE_ROOT}"
    local cmd=(
        rsync -e "ssh $(_ssh_opts)"
        -rvh --update --delete
        "${PULL_REMOTE}:${PULL_REMOTE_SOURCE}"
        "$target"/
    )

    echo "Pulling flake from ${PULL_REMOTE}:${PULL_REMOTE_SOURCE} to ${target}..."
    "${cmd[@]}"
}

cmd_push() {
    local source="${1:-$NH_FLAKE_ROOT}"
    local cmd=(
        rsync -e "ssh $(_ssh_opts)"
        -rvh --update --delete
        "$source"/
        "${PULL_REMOTE}:${PULL_REMOTE_SOURCE}"
    )

    echo "Pushing flake from ${source} to ${PULL_REMOTE}:${PULL_REMOTE_SOURCE}..."
    "${cmd[@]}"
}

cmd_shell() {
    echo "Opening dev shell for flake..."
    local cmd=(
        env NIX_CONFIG="extra-experimental-features = nix-command flakes"
        nix develop
    )
    "${cmd[@]}"
}

cmd_tuckr() {
    local configs_dir="$DOTFILES_DIR/Configs"
    local exclude_dirs=("systemd")

    if ! command -v tuckr &>/dev/null; then
        echo "ERROR: 'tuckr' is not installed or not on PATH." >&2
        return 1
    fi

    if [ ! -d "$configs_dir" ]; then
        echo "ERROR: Configs directory '$configs_dir' not found." >&2
        return 1
    fi

    echo "Running: tuckr set -f -y -e ${exclude_dirs[*]} \*"
    tuckr set -f -y -e "${exclude_dirs[@]}" \*
}

help() {
    cat <<EOF
Usage: $(basename "$0") <command> [<args>] [--flags]

Commands:
  init [TARGET]     Build and activate configuration.
                    TARGET can be a hostname (runs 'nixos-rebuild
                    switch') or user@hostname (runs 'home-manager
                    switch'). When omitted, auto-detects NixOS vs
                    non-NixOS.
    --use-nh        Use 'nh os switch' / 'nh home switch' from
                    nixpkgs-26.05 instead of nixos-rebuild / home-manager.
  bootstrap         Run the two-stage SSHFS + rsync pipeline
                    (first stage / second stage bootstrap).
  clean             Run 'nh clean all' to garbage-collect old
                    Nix generations.
  pull [DEST]       Rsync the flake from the remote host.
                    DEST defaults to the script directory.
  push [SOURCE]     Rsync the flake to the remote host.
                    SOURCE defaults to the script directory.
  shell             Open a nix dev shell for the flake.
  tuckr             Run 'tuckr set' with all config directories
                    from dotfiles/Configs (excluding systemd).
  help              Show this usage message.
EOF
}

main() {
    case "${1:-}" in
    init)
        shift
        local target=""
        local use_nh="false"

        # Parse flags before the positional target
        while [ $# -gt 0 ] && [[ "$1" == -* ]]; do
            case "$1" in
            --use-nh)
                use_nh="true"
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                help >&2
                exit 1
                ;;
            esac
        done

        # Remaining positional arg is the target
        if [ $# -gt 0 ]; then
            target="$1"
            shift
        fi

        cmd_init "$target" "$use_nh"
        ;;
    bootstrap)
        cmd_bootstrap
        ;;
    clean)
        shift
        cmd_clean "$@"
        ;;
    pull)
        shift
        cmd_pull "${1:-}"
        ;;
    push)
        shift
        cmd_push "${1:-}"
        ;;
    shell)
        cmd_shell
        ;;
    tuckr)
        cmd_tuckr
        ;;
    help)
        help
        ;;
    *)
        help >&2
        exit 1
        ;;
    esac
}

if ! main "$@"; then
    exit 1
fi
