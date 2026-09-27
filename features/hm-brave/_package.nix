{
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
  nix-update-script,
  lib,
  # runtime deps — trim/extend based on `ldd` against the extracted binary
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
  libx11,
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
}: let
  version = "1.96.59"; # placeholder — see updateScript below

  # Brave publishes per-arch .deb assets on the same GitHub Releases page
  # they tag for every stable release, so we can point nix-update-script
  # at the exact same mechanism the Zed module uses.
  assets = {
    "x86_64-linux" = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_amd64.deb";
      sha256 = "sha256-sFEpxpB2cLICni8Bdz0ZLIuHwwdbJYc+o7wia7DxXx4=";
    };
    "aarch64-linux" = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_arm64.deb";
      sha256 = "sha256-uCp6SIybwMexj+oaLaistJ9CtKhWST1qTOdaC5pJ/uM=";
    };
  };

  system = stdenv.hostPlatform.system;

  info =
    if lib.hasAttr system assets
    then assets.${system}
    else lib.throwError "brave-bin: unsupported system ${system}";

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
    libx11
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
    systemd # for libudev
    vulkan-loader
  ];

  libPath = lib.makeLibraryPath nixDeps;
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
      ln -s "$out/opt/brave.com/brave/brave" "$out/bin/${executableName}"

      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" \
        "$out/opt/brave.com/brave/brave"

      # patch the other ELF binaries/libs shipped alongside it
      for f in "$out/opt/brave.com/brave"/*.so* "$out/opt/brave.com/brave/chrome_crashpad_handler" "$out/opt/brave.com/brave/brave_crashpad_handler"; do
        [ -e "$f" ] || continue
        patchelf --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" "$f" || true
      done

      wrapProgram "$out/opt/brave.com/brave/brave" \
        --prefix LD_LIBRARY_PATH ":" ${libPath}
    '';

    passthru = {
      updateScript = nix-update-script {
        extraArgs = [
          "--version-regex"
          "^v(.+)$"
        ];
      };
    };

    meta = with lib; {
      description = "Privacy-oriented browser for Desktop and Laptop, built on Chromium";
      homepage = "https://brave.com/";
      changelog = "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP.md";
      mainProgram = executableName;
      license = licenses.mpl20;
      platforms = attrNames assets;
    };
  })
