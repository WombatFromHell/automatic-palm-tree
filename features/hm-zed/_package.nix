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
  testers,
  lib,
}: let
  # Load mutable metadata
  meta = builtins.fromJSON (builtins.readFile ./metadata.json);

  inherit (meta) version;

  # Construct assets dynamically from metadata hashes
  # We map system -> { url, sha256 }
  assets =
    lib.mapAttrs (_: sha256: {
      url = "https://github.com/zed-industries/zed/releases/download/v${version}/zed-linux-${
        if builtins.elem system ["x86_64-linux"]
        then "x86_64"
        else "aarch64"
      }.tar.gz";
      inherit sha256;
    })
    meta.hashes;

  system = stdenv.hostPlatform.system;

  info =
    if lib.hasAttr system assets
    then assets.${system}
    else lib.throwError "zed-editor-bin: unsupported system ${system}. Available: ${toString (lib.attrNames assets)}";

  nixDeps = [
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

  libPath = lib.makeLibraryPath nixDeps;
  executableName = "zed";

  # FHS Wrapper Definition
  fhsFn = {
    zed-editor,
    additionalPkgs ? pkgs: [],
  }:
    buildFHSEnv {
      name = executableName;
      targetPkgs = pkgs:
        (with pkgs; [
          glibc
        ])
        ++ additionalPkgs pkgs;
      extraInstallCommands = ''
        ln -s "${zed-editor}/share" "$out/"
      '';
      runScript = "${zed-editor}/bin/${executableName}";

      # Prevent the FHS env from creating a user namespace (required for some GPU drivers)
      unshareUser = false;

      passthru = {
        inherit executableName;
        inherit (zed-editor) pname version;
      };
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
    buildInputs = nixDeps;

    src = fetchurl {inherit (info) url sha256;};

    phases = ["unpackPhase" "installPhase"];

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
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" \
        "$out/bin/zed"

      # Patch helper binary
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" \
        "$out/libexec/zed-editor"

      # Wrap with LD_LIBRARY_PATH for safety
      wrapProgram $out/bin/zed \
        --prefix LD_LIBRARY_PATH ":" ${libPath}

      wrapProgram $out/libexec/zed-editor \
        --prefix LD_LIBRARY_PATH ":" ${libPath}
    '';

    passthru = {
      # Expose FHS wrappers
      fhs = fhsFn {zed-editor = finalAttrs.finalPackage;};
      fhsWithPackages = f:
        fhsFn {
          zed-editor = finalAttrs.finalPackage;
          additionalPkgs = f;
        };

      noFHS = finalAttrs.finalPackage;

      tests = {
        remoteServerVersion = testers.testVersion {
          package = finalAttrs.finalPackage.remote_server or finalAttrs.finalPackage;
          # Note: remote_server might not be exposed directly depending on upstream structure
          command = "zed-remote-server-stable-${finalAttrs.version} version";
        };
      };
    };

    meta = with lib; {
      description = "High-performance, multiplayer code editor from the creators of Atom and Tree-sitter";
      homepage = "https://zed.dev";
      changelog = "https://github.com/zed-industries/zed/releases/tag/v${finalAttrs.version}";
      mainProgram = executableName;
      license = licenses.gpl3Only;
      platforms = attrNames assets;
    };
  })
