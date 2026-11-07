{
  fetchFromGitHub,
  lib,
  pinMeta,
  rustPlatform,
  stdenv,
}: let
  # Mutable pin metadata, updated by ./update.sh. `version` is the commit itself, so this is a
  # fixed revision: the archive behind it cannot move, and nothing here auto-discovers a newer one.
  # The upstream releases publish a musl binary and darwin/windows assets only, so the source
  # archive is the linux route, and Cargo.lock (committed, no git sources) fixes the crate set.
  pin = lib.importJSON ./metadata.json;

  src = fetchFromGitHub (pinMeta.gitSource pin stdenv.hostPlatform.system);
in
  rustPlatform.buildRustPackage (finalAttrs: {
    pname = "ank-cli";
    inherit (pin) version;
    inherit src;

    # The crate set comes from the lock file — every crate is fixed by it, which is why there is no
    # cargoHash here. features/hm-yazi is the case that needs `allowBuiltinFetchGit`; this lock file
    # has no git sources, so nothing beyond the vendor dir is fetched.
    cargoLock = {
      lockFile = "${src}/Cargo.lock";
    };

    # `cargo install --git https://github.com/haksolot/ank ank-cli` builds one package. The other
    # workspace crates carry auto-discovered `src/bin` targets (`config-keys`, `entity-fields`,
    # `environment`, `exit-codes`) — internal tools that have no business on a PATH.
    cargoBuildFlags = ["-p" "ank-cli"];

    env = {
      # Vendored crates only: a build that could reach the network would not be reproducible from
      # the lock file.
      CARGO_NET_OFFLINE = "true";
    };

    # Upstream's suite drives real git corpora, and git is not in this build environment — ank's own
    # contract is that its claims live in git refs, so its tests need a working git.
    # shortcut: unchecked build; upgrade by adding pkgs.git to nativeBuildInputs and dropping this.
    doCheck = false;

    meta = {
      description = "Ank — task and decision ledger for AI coding agents, with claims backed by git";
      homepage = "https://github.com/haksolot/ank";
      license = lib.licenses.asl20;
      mainProgram = "ank";
      platforms = pinMeta.pinnedSystems pin;
    };
  })
