{
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
  addDriverRunpath,
  bash,
  dpkg,
  xdg-utils,
  lib,
  pinMeta,
  commandLineArgs ? "",
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libnotify,
  libpulseaudio,
  libsecret,
  libva,
  libvdpau,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxtst,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,
  vulkan-loader,
  wayland,
}: let
  # Mutable pin metadata, written by ./update.sh
  pin = lib.importJSON ./metadata.json;

  inherit (pin) version;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin stdenv.hostPlatform.system;

  # Guard clause: --no-sandbox is never a flag this package should carry. brave://sandbox
  # reports Layer 1 = Namespace with PID/network namespaces and seccomp-BPF TSYNC, so the
  # missing SUID helper is a non-issue and --no-sandbox would only switch the sandbox off.
  flags =
    if lib.hasInfix "--no-sandbox" commandLineArgs
    then throw "brave-bin refuses --no-sandbox in commandLineArgs: the namespace sandbox works here."
    else commandLineArgs;

  # Flags arrive from programs.chromium's override as one string, substituted into the build
  # shell below. Escaped, so a quote or $(...) is an argument, not a build-time execution.
  addFlags = lib.optionalString (flags != "") "--add-flags ${lib.escapeShellArg flags}";
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "brave-bin";
    inherit version;

    nativeBuildInputs = [
      addDriverRunpath
      bash
      dpkg
      makeWrapper
      patchelf
    ];
    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libgbm
      libnotify
      libpulseaudio
      libsecret
      libva
      libvdpau
      libx11
      libxcb
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxkbcommon
      libxrandr
      libxrender
      libxscrnsaver
      libxtst
      nspr
      nss
      pango
      # Wayland screen capture: the app dlopens libpipewire-0.3.so.0.
      pipewire
      systemd
      vulkan-loader
      wayland
    ];

    src = fetchurl asset;

    phases = ["unpackPhase" "installPhase"];

    unpackPhase = ''
      runHook preUnpack
      # dpkg-deb reads whatever compression Brave ships (`ar p data.tar.xz | tar xJf -` only reads
      # xz and dies the day the deb switches to zstd). The tarfile goes to tar ourselves, with
      # permissions dropped: chrome-sandbox ships setuid root, and a builder running as nixbld
      # cannot chmod that bit -- dpkg-deb -x passes -p and fails the whole extraction. The mode is
      # not needed: the namespace sandbox works here.
      dpkg-deb --fsys-tarfile "$src" | tar xf - --no-same-permissions --no-same-owner
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"
      cp -R opt "$out/opt"
      cp -R usr/share "$out/share"

      rpath="${lib.makeLibraryPath ([stdenv.cc.cc] ++ finalAttrs.buildInputs)}"
      interp="$(cat "$NIX_CC/nix-support/dynamic-linker")"

      # Executables need the interpreter as well as the rpath. The deb's helpers point at
      # /lib64/ld-linux-x86-64.so.2, which only exists as a host symlink -- crashpad would
      # start against whatever glibc the host happens to have, or not at all.
      for exe in brave chrome_crashpad_handler chrome-sandbox; do
        p="$out/opt/brave.com/brave/$exe"
        [ -e "$p" ] || continue
        patchelf --set-interpreter "$interp" --set-rpath "$rpath" "$p"
      done

      # Shared objects take the rpath only. No `|| true`: a patchelf failure is a build failure.
      for so in "$out"/opt/brave.com/brave/*.so*; do
        [ -e "$so" ] || continue
        patchelf --set-rpath "$rpath" "$so"
      done

      # brave-browser is a #!/bin/bash script; /bin/bash is a host symlink too.
      sed -i "1s|^#!/bin/bash|#!${bash}/bin/bash|" "$out/opt/brave.com/brave/brave-browser"

      sed -i "s|^Exec=/usr/bin/brave-browser-stable|Exec=brave-browser|" \
        "$out/share/applications/com.brave.Browser.desktop" \
        "$out/share/applications/brave-browser.desktop"

      install -Dm644 "$out/opt/brave.com/brave/product_logo_128.png" \
        "$out/share/icons/hicolor/128x128/apps/brave-browser.png"

      # Always wrapped, one code path: the GPU driver dir (/run/opengl-driver/lib on NixOS,
      # nixGL's driver elsewhere) and xdg-utils belong in the environment whether or not
      # flags are set. Both entry points carry the flags, because the launcher script execs the
      # binary beside it rather than $out/bin/brave.
      for name in brave brave-browser; do
        makeWrapper "$out/opt/brave.com/brave/$name" "$out/bin/$name" \
          --prefix LD_LIBRARY_PATH : "${addDriverRunpath.driverLink}/lib" \
          --prefix PATH : "${lib.makeBinPath [xdg-utils]}" \
          ${addFlags}
      done

      runHook postInstall
    '';

    meta = {
      description = "Privacy-oriented browser for Desktop and Laptop, built on Chromium";
      homepage = "https://brave.com/";
      changelog = "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP.md";
      mainProgram = "brave";
      license = lib.licenses.mpl20;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = pinMeta.pinnedSystems pin;
    };
  })
