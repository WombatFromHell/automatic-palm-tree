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

  system = stdenv.hostPlatform.system;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin system;

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

    src = fetchurl {inherit (asset) url sha256;};

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

      # Patch main binary
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ finalAttrs.buildInputs)}" \
        "$out/bin/zed"

      # Patch helper binary
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ finalAttrs.buildInputs)}" \
        "$out/libexec/zed-editor"

      # Wrap with LD_LIBRARY_PATH for safety
      wrapProgram $out/bin/zed \
        --prefix LD_LIBRARY_PATH ":" ${lib.makeLibraryPath finalAttrs.buildInputs}

      wrapProgram $out/libexec/zed-editor \
        --prefix LD_LIBRARY_PATH ":" ${lib.makeLibraryPath finalAttrs.buildInputs}
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
