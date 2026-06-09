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
  nix-update-script,
  testers,
  lib,
}: let
  version = "1.6.2-pre";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/zed-industries/zed/releases/download/v${version}/zed-linux-x86_64.tar.gz";
      sha256 = "sha256-TjpfBP35JwoSgZPYUVzXgspNyfLJ1ojtiJXXNj03IoY=";
    };
  };

  system = stdenv.hostPlatform.system;

  info =
    if lib.hasAttr system assets
    then assets.${system}
    else lib.throwError "zed-editor-bin: unsupported system ${system}";

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

  # buildFHSEnv allows for users to use the existing Zed extensions
  fhs = {
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

      # Prevent the FHS env from creating a user namespace.
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

      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" \
        "$out/bin/zed"

      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.makeLibraryPath ([stdenv.cc.cc] ++ nixDeps)}" \
        "$out/libexec/zed-editor"

      wrapProgram $out/bin/zed \
        --prefix LD_LIBRARY_PATH ":" ${libPath}

      wrapProgram $out/libexec/zed-editor \
        --prefix LD_LIBRARY_PATH ":" ${libPath}
    '';

    passthru = {
      updateScript = nix-update-script {
        extraArgs = [
          "--version-regex"
          "^v(?!.*(?:0\.999999\.0|0\.9999-temporary)$)(.+)$"
        ];
      };
      fhs = fhs {zed-editor = finalAttrs.finalPackage;};
      fhsWithPackages = f:
        fhs {
          zed-editor = finalAttrs.finalPackage;
          additionalPkgs = f;
        };
      noFHS = finalAttrs.finalPackage;
      tests = {
        remoteServerVersion = testers.testVersion {
          package = finalAttrs.finalPackage.remote_server;
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
