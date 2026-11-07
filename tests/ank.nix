# nix-unit attributes for features/hm-ank/_package.nix: the `cargo install --git … ank-cli`
# semantics that are visible as evaluated values. Nothing is built and no crate is fetched — these
# force keys of `drvAttrs`, never `outPath`, which is what would pull the crate set behind
# Cargo.lock (same reason tests/home.nix's yazi check forces only `version`).
let
  s = import ./support.nix;
  inherit (s) lib pkgs;
  # Read straight from lib/pin-meta.nix, the way tests/pins.nix does, so a pin's own contract is
  # checked rather than the copy the package-set overlay hands out.
  pinMeta = import ../lib/pin-meta.nix {inherit lib;};

  # Called exactly as production does: pinMeta arrives through the loader's package set.
  package = pkgs.callPackage ../features/hm-ank/_package.nix {};
  pin = builtins.fromJSON (builtins.readFile ../features/hm-ank/metadata.json);
in {
  # `cargo install --git https://github.com/haksolot/ank ank-cli` builds one package. The workspace
  # also has auto-discovered `src/bin` targets in ank-core and ank-contract, so an unrestricted
  # build puts four internal tools (`config-keys`, `entity-fields`, `environment`, `exit-codes`) on
  # PATH beside the CLI.
  testAnkBuildsOnlyTheCliPackage = {
    expr = package.drvAttrs.cargoBuildFlags;
    expected = ["-p" "ank-cli"];
  };

  # The binary lands in the store, named after the pinned commit (the house pin stores the commit
  # as `version`, so nixpkgs names the derivation from it). `~/.cargo/bin` is never written: the
  # derivation has no cargo-install step, so the home dir is not part of this build at all.
  # Only derivation attributes are forced — no build, no crate fetch.
  testAnkOutputIsAStorePathNamedForThePin = {
    expr = package.drvAttrs.name;
    expected = "ank-cli-${pin.version}";
  };

  # Crates are vendored from the committed Cargo.lock, so the build reaches no network and there is
  # no cargoHash to keep in step with the pin. nixpkgs flattens `env` into `drvAttrs`.
  testAnkBuildsOffline = {
    expr = package.drvAttrs.CARGO_NET_OFFLINE;
    expected = "true";
  };

  # Upstream's suite drives real git corpora, and git is not in this build environment, so the
  # derivation ships unchecked — the gate checks its shape instead.
  testAnkShipsUnchecked = {
    expr = package.drvAttrs.doCheck;
    expected = false;
  };

  # The command the package promises, and the pin it was built from: a fixed revision (`strategy:
  # none`), a source nar (`kind: nar`), and only the one system this flake's hosts run.
  testAnkNamesItsProgramAndPin = {
    expr = {
      mainProgram = package.meta.mainProgram;
      version = package.drvAttrs.version;
      inherit (pin) kind strategy;
      systems = pinMeta.pinnedSystems pin;
    };
    expected = {
      mainProgram = "ank";
      inherit (pin) version;
      kind = "nar";
      strategy = "none";
      systems = ["x86_64-linux"];
    };
  };
}
