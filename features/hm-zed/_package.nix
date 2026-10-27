{
  stdenv,
  fetchurl,
  patchelf,
  glib,
  makeWrapper,
  libbsd,
  libX11,
  libXau,
  libxcb,
  libXdmcp,
  libxkbcommon,
  zlib,
  alsa-lib,
  wayland,
  vulkan-loader,
  buildFHSEnv,
  lib,
  pinMeta,
}: let
  # Mutable pin metadata, written by ./update.sh
  pin = lib.importJSON ./metadata.json;

  inherit (pin) version;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin stdenv.hostPlatform.system;

  executableName = "zed";

  # FHS Wrapper Definition
  fhsFn = zed-editor:
    buildFHSEnv {
      name = executableName;
      targetPkgs = pkgs: with pkgs; [glibc];
      extraInstallCommands = ''
        ln -s "${zed-editor}/share" "$out/"
      '';
      runScript = "${zed-editor}/bin/${executableName}";

      # Prevent the FHS env from creating a user namespace (required for some GPU drivers)
      unshareUser = false;

      meta =
        zed-editor.meta
        // {
          description = ''
            Wrapped variant of ${zed-editor.pname} which launches in a FHS compatible environment.
            Should allow for easy usage of extensions without nix-specific modifications.
          '';
        };
    };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "zed-editor-bin";
    inherit version;

    nativeBuildInputs = [patchelf makeWrapper];
    buildInputs = [
      glib
      libbsd
      libX11
      libXau
      libxcb
      libXdmcp
      libxkbcommon
      zlib
      alsa-lib
      wayland
      vulkan-loader
    ];

    src = fetchurl asset;

    phases = ["unpackPhase" "installPhase"];

    # NOTE: do not use stdenv's default unpackPhase — unpackFile cd's into the
    # single top-level dir (zed.app) and sets a relative sourceRoot, which
    # breaks the appdir lookup below.
    unpackPhase = ''
      tar xzf "$src"
    '';

    installPhase = ''
      appdir="$(find . -maxdepth 1 -type d -name '*.app' -print -quit)"

      mkdir -p $out/{bin,libexec,share}

      cp "$appdir/bin/zed"       $out/bin/
      cp "$appdir/libexec/zed-editor" $out/libexec/
      cp -R "$appdir/share"/* $out/share/

      # Patch both binaries and wrap them with LD_LIBRARY_PATH, identically
      rpath="${lib.makeLibraryPath ([stdenv.cc.cc] ++ finalAttrs.buildInputs)}"
      linker="$(cat $NIX_CC/nix-support/dynamic-linker)"
      for f in "$out/bin/zed" "$out/libexec/zed-editor"; do
        patchelf --set-interpreter "$linker" --set-rpath "$rpath" "$f"
        wrapProgram "$f" --prefix LD_LIBRARY_PATH ":" "$rpath"
      done
    '';

    passthru = {
      # Expose FHS wrappers
      fhs = fhsFn finalAttrs.finalPackage;
      noFHS = finalAttrs.finalPackage;
    };

    meta = with lib; {
      description = "High-performance, multiplayer code editor from the creators of Atom and Tree-sitter";
      homepage = "https://zed.dev";
      changelog = "https://github.com/zed-industries/zed/releases/tag/v${finalAttrs.version}";
      mainProgram = executableName;
      license = licenses.gpl3Only;
      platforms = pinMeta.pinnedSystems pin;
    };
  })
