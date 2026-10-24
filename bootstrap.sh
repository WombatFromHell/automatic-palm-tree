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
NH_SPEC="github:NixOS/nixpkgs/nixos-26.05#nh"

# Cache flags for every command this script runs: urls + keys come from
# modules/cache-registry.nix, so the registry stays the only place a cache is written. Without them
# a first switch builds cache-fed paths locally (kernel compile, firmware VM) on a machine with no
# swap yet. argv beats env: `--option` survives sudo's env_reset and applies whether or not the
# invoking user is a trusted user. Eval only - no builds.
cache_flags=()
cache_flags_init() {
    local file="$SCRIPT_DIR/modules/cache-registry.nix"
    local urls keys
    urls="$(nix eval --impure --raw --file "$file" substituters)" || {
        echo "ERROR: cannot eval cache urls from '$file'." >&2
        return 1
    }
    keys="$(nix eval --impure --raw --file "$file" trustedPublicKeys)" || {
        echo "ERROR: cannot eval cache keys from '$file'." >&2
        return 1
    }
    cache_flags=(--option extra-substituters "$urls" --option extra-trusted-public-keys "$keys")
}
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
    # Swap for the rebuild itself. The persistent swapfile is created by a systemd
    # unit that only runs at boot of the *new* system, so the first rebuild has no
    # swap at all and OOMs. zram needs no disk and no filesystem (a btrfs swapfile
    # cannot be compressed or snapshotted), so make one here and keep going.
    local maybe_sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        maybe_sudo="sudo"
    fi

    # Any active swap (zram or a swapfile) already covers the rebuild.
    if [ "$(tail -n +2 /proc/swaps | wc -l)" -gt 0 ]; then
        echo "Swap already active - skipping swap preparation."
        return 0
    fi

    echo "Creating zram swap to avoid OOM during the rebuild..."
    if ! $maybe_sudo bash -c '
        modprobe zram
        ram_kb=$(awk "/MemTotal/ {print \$2}" /proc/meminfo)
        size=$((ram_kb / 2 * 1024)) # half of RAM, in bytes; zram is compressed, so it costs less than it swaps
        target=/sys/block/zram0/reset
        [ -w "$target" ] || target=/sys/block/zram0/disksize
        [ -w /sys/block/zram0/compression ] && echo zstd > /sys/block/zram0/compression
        echo "$size" > "$target"
        mkswap /dev/zram0 >/dev/null
        swapon -p 5 /dev/zram0
    '; then
        echo "WARN: zram swap setup failed - continuing anyway." >&2
        return 0
    fi

    echo "zram swap active: $(swapon --show)"
}

cmd_init() {
    local target="${1:-}"
    local use_nh="${2:-false}"
    local flake="${NH_FLAKE_ROOT:-$SCRIPT_DIR}"

    if ! cache_flags_init; then
        return 1
    fi

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

    # Two-stage bootstrap (opt-in): a machine with too little memory + swap for the full build
    # switches the light `<host>-boot` config first — that one carries the swap feature and
    # nothing else — then the full config. A host without `bootFeatures` has no `-boot`
    # attribute, so it stays single-stage; `FLAKEROOT_STAGED=0` keeps the old path regardless
    # of memory, `FLAKEROOT_STAGED=1` forces staging, and `FLAKEROOT_BOOT_MEM_MIN` (KiB) moves
    # the threshold.
    local staged="false"
    local avail=0
    local swap_free=0

    if [ "$mode" = "os" ] && [ "${FLAKEROOT_STAGED:-}" != "0" ]; then
        avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        swap_free=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
        if [ "${FLAKEROOT_STAGED:-}" = "1" ] ||
            [ $((avail + swap_free)) -lt "${FLAKEROOT_BOOT_MEM_MIN:-6291456}" ]; then
            staged="true"
        fi
    fi

    if [ "$staged" = "true" ]; then
        local host="${target:-$(hostname)}"
        echo "Low memory (${avail} KiB RAM + ${swap_free} KiB swap) - staging '$host'..."

        if nix develop "$flake" -c sudo nixos-rebuild switch --flake "${flake}#${host}-boot" "${cache_flags[@]}" -L; then
            # No remote builder here, so throttle local builds instead. Stage 1 already sets
            # `nix.settings.max-jobs = 1` for the daemon; NIX_CONFIG covers daemon-less builds.
            echo "Stage 2: full '$host' config, one build job at a time..."
            NIX_CONFIG="max-jobs = 1 cores = 1" nix develop "$flake" -c sudo nixos-rebuild switch --flake "$flake_ref" "${cache_flags[@]}" -L
            return 0
        fi

        echo "WARN: stage 1 failed ('${host}-boot' may not be declared) - switching the full config." >&2
    fi

    if [ "$use_nh" = "true" ]; then
        local nh_cmd=(
            env NH_FLAKE_ROOT="$NH_FLAKE_ROOT"
            nix run "$NH_SPEC" --
        )

        if [ "$mode" = "os" ]; then
            echo "Running 'nh os switch'..."
            "${nh_cmd[@]}" os switch "$flake_ref" -- "${cache_flags[@]}" -L
        else
            echo "Running 'nh home switch'..."
            "${nh_cmd[@]}" home switch "$flake_ref" -- "${cache_flags[@]}" -L
        fi
    else
        local cmd=(nix develop "$flake" -c)

        if [ "$mode" = "os" ]; then
            cmd+=(sudo nixos-rebuild switch --flake "$flake_ref" "${cache_flags[@]}" -L)
        else
            cmd+=(home-manager switch --flake "$flake_ref" "${cache_flags[@]}" -L)
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
        env "NH_FLAKE_ROOT=$NH_FLAKE_ROOT"
        nix run "$NH_SPEC" --
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
    if ! cache_flags_init; then
        return 1
    fi
    nix develop "${cache_flags[@]}"
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
