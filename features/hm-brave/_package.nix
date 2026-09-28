{
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
  lib,
  # Runtime deps trimmed for brevity in this example, keep your full list
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
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  wayland,
}: let
  # Load mutable metadata
  meta = builtins.fromJSON (builtins.readFile ./metadata.json);

  inherit (meta) version;

  # Construct assets dynamically from metadata
  assets =
    lib.mapAttrs (_: sha256: {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_${
        if builtins.elem system ["x86_64-linux"]
        then "amd64"
        else "arm64"
      }.deb";
      inherit sha256;
    })
    meta.hashes;

  system = stdenv.hostPlatform.system;

  info =
    if lib.hasAttr system assets
    then assets.${system}
    else lib.throwError "brave-bin: unsupported system ${system}. Available: ${toString (lib.attrNames assets)}";

  nixDeps = [
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
    mesa
    nspr
    nss
    pango
    systemd
    vulkan-loader
    wayland
  ];

  executableName = "brave";
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "brave-bin";
    inherit version;

    nativeBuildInputs = [patchelf makeWrapper];
    buildInputs = nixDeps;

    src = fetchurl {inherit (info) url sha256;};

    phases = ["unpackPhase" "installPhase"];

    unpackPhase = ''
      ar p "$src" data.tar.xz | tar xJf - --no-same-permissions --no-same-owner
    '';

    installPhase = ''
      mkdir -p $out
      cp -R opt $out/opt
      cp -R usr/share $out/share

      mkdir -p $out/bin
      rpath="${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}"

      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "$rpath" \
        "$out/opt/brave.com/brave/brave"

      for f in "$out/opt/brave.com/brave"/*.so* "$out/opt/brave.com/brave/chrome_crashpad_handler" "$out/opt/brave.com/brave/brave_crashpad_handler"; do
        [ -e "$f" ] || continue
        patchelf --set-rpath "$rpath" "$f" || true
      done

      sed -i "s|^Exec=/usr/bin/brave-browser-stable|Exec=$out/bin/brave-browser|" \
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
      platforms = attrNames assets;
    };
  })
