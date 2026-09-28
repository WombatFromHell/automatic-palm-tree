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
}: let
  # Load mutable metadata
  meta = builtins.fromJSON (builtins.readFile ./metadata.json);

  inherit (meta) version;

  system = stdenv.hostPlatform.system;

  # Per-system release asset from metadata hashes
  info = let
    sha256 = meta.hashes.${system} or null;
  in
    if sha256 == null
    then lib.throw "zed-editor-bin: unsupported system ${system}. Available: ${toString (lib.attrNames meta.hashes)}"
    else {
      url = "https://github.com/zed-industries/zed/releases/download/v${version}/zed-linux-${
        if system == "x86_64-linux"
        then "x86_64"
        else "aarch64"
      }.tar.gz";
      inherit sha256;
    };

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
    buildInputs = nixDeps;

    src = fetchurl {inherit (info) url sha256;};

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
      fhs = fhsFn finalAttrs.finalPackage;
      noFHS = finalAttrs.finalPackage;
    };

    meta = with lib; {
      description = "High-performance, multiplayer code editor from the creators of Atom and Tree-sitter";
      homepage = "https://zed.dev";
      changelog = "https://github.com/zed-industries/zed/releases/tag/v${finalAttrs.version}";
      mainProgram = executableName;
      license = licenses.gpl3Only;
      platforms = attrNames meta.hashes;
    };
  })
