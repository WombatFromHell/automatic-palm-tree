#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory (the flake root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# remote host used by pull, first_stage, and second_stage
PULL_REMOTE="nxxel@192.168.1.153"
PULL_REMOTE_PORT="2222"
PULL_REMOTE_SOURCE="~/Projects/nix/"
#
SSHFS_OPTS=(-p 2222)
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
STAGE2_ANSIBLE_ROOT="$SSHFS_MNTDIR/Projects/silver-octo-bassoon"
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
        if ! sshfs "${SSHFS_OPTS[@]}" "$SSHFS_REMOTE" "$SSHFS_MNTDIR"; then
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
    if ! "${RSYNC_BASECMD[@]}" "$STAGE2_ANSIBLE_ROOT" "$ANSIBLE_ROOT"; then
        echo "Error: something went wrong when rsync'ing '$ANSIBLE_ROOT'!"
        return 1
    fi

    ln -sf "$ANSIBLE_ROOT/files" "$HOME/.config/dotfiles"

    echo "Second stage bootstrap complete!"
    return 0
}

cmd_init() {
    local target="${1:-}"
    local flake="${NH_FLAKE_ROOT:-$SCRIPT_DIR}"

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
            echo "Detected NixOS — running system switch..."
        else
            mode="home"
            echo "Detected ${os_name} — running home switch..."
        fi
    fi

    # Ensure home-manager is initialized before we can use it
    if [ "$mode" = "home" ] && {
        ! command -v home-manager &>/dev/null ||
            [ ! -f "$HOME/.config/home-manager/flake.nix" ]
    }; then
        echo "Home Manager not yet initialized — running init..."
        env NIX_CONFIG="extra-experimental-features = nix-command flakes" \
            nix run "github:nix-community/home-manager/master" -- init --switch
    fi

    local cmd=(
        env NIX_CONFIG="extra-experimental-features = nix-command flakes" "NH_FLAKE_ROOT=$NH_FLAKE_ROOT"
        nix develop "$flake" -c
    )

    if [ "$mode" = "os" ]; then
        cmd+=(sudo nixos-rebuild switch --flake "$flake_ref" -L -v)
    else
        cmd+=(home-manager switch --flake "$flake_ref")
    fi

    echo "Running inside flake dev shell..."
    "${cmd[@]}"
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

cmd_pull() {
    local target="${1:-$NH_FLAKE_ROOT}"
    local cmd=(
        rsync -e "ssh -p ${PULL_REMOTE_PORT}"
        -rvh --update --delete
        "${PULL_REMOTE}:${PULL_REMOTE_SOURCE}"
        "$target"
    )

    echo "Pulling flake from ${PULL_REMOTE}:${PULL_REMOTE_SOURCE} to ${target}..."
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

help() {
    cat <<EOF
Usage: $(basename "$0") <command> [<args>] [--flags]

Commands:
  init [TARGET]     Build and activate configuration.
                    TARGET can be a hostname (runs 'nixos-rebuild
                    switch') or user@hostname (runs 'home-manager
                    switch'). When omitted, auto-detects NixOS vs
                    non-NixOS.
    --cores N       Limit build parallelism to N cores (passed
                    through to nix/build).
  bootstrap         Run the two-stage SSHFS + rsync pipeline
                    (first stage / second stage bootstrap).
  clean             Run 'nh clean all' to garbage-collect old
                    Nix generations.
  pull [DEST]       Rsync the flake from the remote host.
                    DEST defaults to the script directory.
  shell             Open a nix dev shell for the flake.
  help              Show this usage message.
EOF
}

main() {
    case "${1:-}" in
    init)
        shift
        local cores=""
        local target=""

        # Parse flags before the positional target
        while [ $# -gt 0 ] && [[ "$1" == -* ]]; do
            case "$1" in
            --cores)
                if [ $# -lt 2 ]; then
                    echo "Error: --cores requires a value." >&2
                    exit 1
                fi
                cores="$2"
                shift 2
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

        cmd_init "$target" "$cores"
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
    shell)
        cmd_shell
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
