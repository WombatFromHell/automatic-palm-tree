#!/usr/bin/env bash
set -euo pipefail

# stage 1 bootstrap
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
RSYNC_BASECMD="rsync -rvh --update --delete"
#
STAGE2_ANSIBLE_ROOT="$SSHFS_MNTDIR/Projects/silver-octo-bassoon"
ANSIBLE_ROOT="$HOME/.ansible-root"
#
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

  echo "Mounting sshfs remote..."
  if ! sshfs "${SSHFS_OPTS[@]}" "$SSHFS_REMOTE" "$SSHFS_MNTDIR"; then
    echo "Error: something went wrong when mounting the sshfs remote!"
    return 1
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
      gpg --import-key "$src"
    else
      echo "WARN: key '$src' not found, skipping." >&2
    fi
  done

  echo "First stage bootstrap complete!"
  return 0
}

second_stage() {
  if ! "$RSYNC_BASECMD" "$STAGE2_ANSIBLE_ROOT" "$ANSIBLE_ROOT"; then
    echo "Error: something went wrong when rsync'ing '$ANSIBLE_ROOT'!"
    return 1
  fi

  ln -sf "$ANSIBLE_ROOT/files" "$HOME/.config/dotfiles"

  echo "Second stage bootstrap complete!"
  return 0
}

main() {
  first_stage
  second_stage
}

if ! main; then
  exit 1
fi
