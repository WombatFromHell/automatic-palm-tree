{
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
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
  systemd,
  vulkan-loader,
  wayland,
}: let
  # Mutable pin metadata, written by ./update.sh
  pin = lib.importJSON ./metadata.json;

  inherit (pin) version;

  system = stdenv.hostPlatform.system;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin system;

  executableName = "brave";

  # programs.chromium.commandLineArgs arrives as one string; the desktop files call this launcher.
  desktopArgs = lib.optionalString (commandLineArgs != "") (" " + commandLineArgs);
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "brave-bin";
    inherit version;

    nativeBuildInputs = [patchelf makeWrapper];
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
      systemd
      vulkan-loader
      wayland
    ];

    src = fetchurl {inherit (asset) url sha256;};

    phases = ["unpackPhase" "installPhase"];

    unpackPhase = ''
      ar p "$src" data.tar.xz | tar xJf - --no-same-permissions --no-same-owner
    '';

    installPhase = ''
      mkdir -p $out
      cp -R opt $out/opt
      cp -R usr/share $out/share

      mkdir -p $out/bin
      rpath="${lib.makeLibraryPath ([stdenv.cc.cc] ++ finalAttrs.buildInputs)}"

      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "$rpath" \
        "$out/opt/brave.com/brave/brave"

      for f in "$out/opt/brave.com/brave"/*.so* "$out/opt/brave.com/brave/chrome_crashpad_handler" "$out/opt/brave.com/brave/brave_crashpad_handler"; do
        [ -e "$f" ] || continue
        patchelf --set-rpath "$rpath" "$f" || true
      done

      sed -i "s|^Exec=/usr/bin/brave-browser-stable|Exec=brave-browser${desktopArgs}|" \
        "$out/share/applications/com.brave.Browser.desktop" \
        "$out/share/applications/brave-browser.desktop"

      install -Dm644 "$out/opt/brave.com/brave/product_logo_128.png" \
        "$out/share/icons/hicolor/128x128/apps/brave-browser.png"

      ln -s "$out/opt/brave.com/brave/brave" "$out/bin/brave"
      ln -s "$out/opt/brave.com/brave/brave-browser" "$out/bin/brave-browser"
    '';

    meta = with lib; {
      description = "Privacy-oriented browser for Desktop and Laptop, built on Chromium";
      homepage = "https://brave.com/";
      changelog = "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP.md";
      mainProgram = executableName;
      license = licenses.mpl20;
      platforms = pinMeta.pinnedSystems pin;
    };
  })
