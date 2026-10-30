{
  stdenv,
  fetchurl,
  lib,
  pinMeta,
}: let
  # Mutable pin metadata, written by ./update.sh
  pin = lib.importJSON ./metadata.json;

  inherit (pin) version;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin stdenv.hostPlatform.system;
in
  # Ghostty upstream ships no binary release, so this takes the pkgforge AppImage
  # instead of nixpkgs' `ghostty`, which builds from source with zig. The AppImage's
  # payload is a self-contained AppDir: the launcher (bin/ghostty), the app
  # (shared/bin/ghostty), every shared library it needs, and the resource trees
  # (share/ghostty, share/terminfo, share/glib-2.0/schemas, share/bat,
  # share/systemd/user, share/dbus-1/services). Extracted into the store it keeps
  # working unpatched — the launcher is statically linked and derives its AppDir from
  # /proc/self/exe, exporting SHARUN_DIR, XDG_DATA_DIRS, TERMINFO, GSETTINGS_SCHEMA_DIR,
  # TEXTDOMAINDIR and the GL/driver search paths relative to it. So there is nothing to
  # patchelf and nothing to makeWrapper here; GPU drivers come from the nixGL wrapper
  # the home module applies (see ./home.nix).
  # shortcut: the AppDir's bundled libs have build-time paths rewritten to /tmp/EKFs=
  # (X11 locale, iso-codes, a bundled fontconfig conf dir). None is reachable here and
  # the launcher's own env covers locales, schemas and fonts; upgrade if UI translation
  # or a bundled font ever has to resolve.
  stdenv.mkDerivation (finalAttrs: {
    pname = "ghostty-bin";
    inherit version;

    src = fetchurl asset;

    phases = ["unpackPhase" "installPhase"];

    # The AppImage runtime refuses to run from a read-only store path, so unpack a
    # writable copy of it. `--appimage-extract` writes the AppDir into $PWD.
    unpackPhase = ''
      cp "$src" ghostty.AppImage
      chmod +x ghostty.AppImage
      ./ghostty.AppImage --appimage-extract
    '';

    installPhase = ''
      mkdir -p $out
      cp -a squashfs-root/. $out/

      # AppImage scaffolding: the runtime entry points and hooks are only how the
      # .AppImage bootstraps itself, and the store already has bin/ghostty.
      rm -f $out/AppRun $out/AppRun.sh $out/AppRun.lib $out/dash $out/sharun \
        $out/.env $out/.DirIcon $out/bin/*.hook

      # The AppDir keeps its desktop entry and icon at the root; the store wants them
      # where the desktop search paths look.
      mkdir -p $out/share/applications $out/share/icons/hicolor/128x128/apps
      mv "$out/com.mitchellh.ghostty.desktop" "$out/share/applications/"
      mv "$out/com.mitchellh.ghostty.png" "$out/share/icons/hicolor/128x128/apps/com.mitchellh.ghostty.png"
    '';

    meta = with lib; {
      description = "Fast, native, feature-rich terminal emulator pushing modern features";
      longDescription = ''
        Ghostty upstream ships no binary release for Linux. This is the pkgforge
        AppImage for Ghostty, unpacked into the store rather than built from source.
      '';
      homepage = "https://ghostty.org/";
      downloadPage = "https://github.com/pkgforge-dev/ghostty-appimage";
      changelog = "https://ghostty.org/docs/install/release-notes/${builtins.replaceStrings ["."] ["-"] finalAttrs.version}";
      license = licenses.mit;
      mainProgram = "ghostty";
      platforms = pinMeta.pinnedSystems pin;
    };
  })
