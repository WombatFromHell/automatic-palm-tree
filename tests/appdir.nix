# Build-tier guard for features/hm-ghostty/_package.nix. The eval gate cannot see what a
# derivation puts in its $out, so this re-runs the derivation's *real* installPhase against a
# synthetic AppDir: the AppImage runtime is never executed, only the tree it would extract
# (`squashfs-root/`). The assertions are the store-layout contract the desktop environment and
# Home Manager read — bin/ghostty kept and executable, AppImage scaffolding dropped, the desktop
# entry and icon moved into share/, and the resource trees left alone.
#
# Gated by tests/run.sh on the build's exit status, not on an evaluated value.
let
  s = import ./support.nix;
  inherit (s) pkgs;

  # `src` is never read: unpackPhase below is replaced, so a placeholder keeps the derivation
  # honest without fetching the ~140MB AppImage.
  placeholderSrc = pkgs.writeTextDir "ghostty.AppImage" "";

  # callPackage finds pinMeta through support.nix's overlay, exactly as it does in production
  # where lib/default.nix injects it into the package set — so the derivation needs no argument.
  extracted =
    (pkgs.callPackage ../features/hm-ghostty/_package.nix {}).overrideAttrs
    (_final: _prev: {
      src = placeholderSrc;
      unpackPhase = ''
        mkdir -p squashfs-root/bin
        printf '#!/bin/sh\n' > squashfs-root/bin/ghostty
        chmod +x squashfs-root/bin/ghostty

        # The AppImage runtime's own entry points and hooks, which installPhase deletes.
        touch squashfs-root/AppRun squashfs-root/AppRun.sh squashfs-root/AppRun.lib \
          squashfs-root/dash squashfs-root/sharun squashfs-root/.env squashfs-root/.DirIcon
        touch squashfs-root/bin/ghostty.hook squashfs-root/bin/sharun.hook

        # The desktop entry and icon sit at the AppDir root, not under share/.
        printf '[Desktop Entry]\nType=Application\nName=Ghostty\nExec=ghostty\n' \
          > squashfs-root/com.mitchellh.ghostty.desktop
        printf 'png' > squashfs-root/com.mitchellh.ghostty.png

        # Resource trees the launcher resolves from its own AppDir; none is relocated.
        mkdir -p squashfs-root/share/ghostty squashfs-root/share/terminfo/g \
          squashfs-root/share/glib-2.0/schemas squashfs-root/share/bat/syntaxes \
          squashfs-root/share/dbus-1/services squashfs-root/share/systemd/user
        touch squashfs-root/share/ghostty/expand.spec
        touch squashfs-root/share/terminfo/g/ghostty
        touch squashfs-root/share/glib-2.0/schemas/com.mitchellh.ghostty.gschema.xml
        touch squashfs-root/share/bat/syntaxes/ghostty.sublime-syntax
        touch squashfs-root/share/dbus-1/services/com.mitchellh.ghostty.service
        touch squashfs-root/share/systemd/user/app-com.mitchellh.ghostty.service
      '';
    });
in
  pkgs.runCommand "ghostty-appdir-layout" {dependsOn = [extracted];} ''
    set -e
    P=${extracted}

    test -x "$P/bin/ghostty"
    test ! -e "$P/bin/ghostty.hook"
    test ! -e "$P/bin/sharun.hook"

    test -e "$P/share/applications/com.mitchellh.ghostty.desktop"
    test -e "$P/share/icons/hicolor/128x128/apps/com.mitchellh.ghostty.png"
    # Moved, not copied: the AppDir root must not keep a shadow copy the launcher could pick up.
    test ! -e "$P/com.mitchellh.ghostty.desktop"
    test ! -e "$P/com.mitchellh.ghostty.png"

    for scaffold in AppRun AppRun.sh AppRun.lib dash sharun .env .DirIcon; do
      test ! -e "$P/$scaffold"
    done

    for tree in share/ghostty share/terminfo/g share/glib-2.0/schemas share/bat/syntaxes \
      share/dbus-1/services share/systemd/user; do
      test -d "$P/$tree"
    done

    mkdir -p $out
  ''
