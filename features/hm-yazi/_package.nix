{
  lib,
  pinMeta,
  unstable,
}: let
  # Mutable pin metadata, updated by ./update.sh. `version` is the commit itself, so this is a
  # fixed revision: the archive behind it cannot move, and nothing here auto-discovers a newer one.
  pin = lib.importJSON ./metadata.json;

  # The fork's tree, plus the man pages, which upstream publishes in a separate repository
  # (same rev nixpkgs pins for its own yazi).
  codeSrc = unstable.fetchFromGitHub (pinMeta.gitSource pin unstable.stdenv.hostPlatform.system);
  manSrc = unstable.yazi-unwrapped.passthru.srcs.man_src;

  # `.cargo/config.toml` aliases `cargo xtask` to the workspace's `yazi-build` member, which is
  # how the fork builds; the archive carries it, so the alias resolves.
  buildPhase = ''
    runHook preBuild
    cargo xtask build --target ${unstable.stdenv.hostPlatform.rust.rustcTarget}
    runHook postBuild
  '';
in
  unstable.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "yazi";
    inherit (pin) version;
    inherit buildPhase;

    srcs = [
      codeSrc
      manSrc
    ];
    sourceRoot = codeSrc.name;

    # Cargo.lock pins git sources (the fork's ratatui/termwiz), so the crate set comes from the
    # lock file — every crate and git rev is fixed by it, which is why there is no cargoHash here.
    cargoLock = {
      lockFile = "${codeSrc}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    env = {
      VERGEN_GIT_SHA = pin.version;
      # No git metadata in the store, so vergen reads these; the fork defaults the date to epoch.
      VERGEN_BUILD_DATE = "1970-01-01";
      CARGO_NET_OFFLINE = "true";
      CARGO_PROFILE_RELEASE_LTO = "thin";
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "4";
      CARGO_PROFILE_RELEASE_DEBUG = "0";
      CARGO_PROFILE_RELEASE_STRIP = "symbols";
    };

    nativeBuildInputs = [
      unstable.installShellFiles
      unstable.imagemagick
      unstable.llvmPackages.bintools
    ];

    buildInputs = [unstable.rust-jemalloc-sys];

    postInstall = ''
      installShellCompletion --cmd yazi \
        --bash ./assets/completions/yazi.bash \
        --fish ./assets/completions/yazi.fish \
        --zsh  ./assets/completions/_yazi

      installShellCompletion --cmd ya \
        --bash ./assets/completions/ya.bash \
        --fish ./assets/completions/ya.fish \
        --zsh  ./assets/completions/_ya

      for RES in 16 24 32 48 64 128 256; do
        mkdir -p $out/share/icons/hicolor/"$RES"x"$RES"/apps
        magick assets/logo.png -resize "$RES"x"$RES" $out/share/icons/hicolor/"$RES"x"$RES"/apps/yazi.png
      done

      installManPage ../${manSrc.name}/yazi{.1,-config.5}

      mkdir -p $out/share/applications
      install -m644 assets/yazi.desktop $out/share/applications/
    '';

    meta = {
      description = "Blazing fast terminal file manager written in Rust, based on async I/O (rylos/yazi fork build)";
      homepage = "https://github.com/rylos/yazi";
      license = lib.licenses.mit;
      mainProgram = "yazi";
      platforms = pinMeta.pinnedSystems pin;
      priority = 4; # prefer this override to the nixpkgs variant
    };
  })
