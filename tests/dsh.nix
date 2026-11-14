# nix-unit attributes for features/hm-dsh/_package.nix: the nixpkgs baseline derivation for
# deepseek-harness, built from the pinned release tarball instead of a git checkout.
# Only `drvAttrs` keys are forced, never `outPath` — no build, no npm fetch (same reasoning as
# tests/home.nix's yazi check forcing only `version`).
let
  s = import ./support.nix;
  inherit (s) lib pkgs;
  # Read straight from lib/pin-meta.nix, like tests/pins.nix, so the pin's own contract is
  # what's checked, not the copy the package-set overlay hands out.
  pinMeta = import ../lib/pin-meta.nix {inherit lib;};

  # Invoked the way production does: pinMeta comes from the loader's package set.
  package = pkgs.callPackage ../features/hm-dsh/_package.nix {};
  pin = builtins.fromJSON (builtins.readFile ../features/hm-dsh/metadata.json);
in {
  # The tarball has no `.git`, so the commit stamp is the pinned rev itself and the derivation
  # is named for it (house pins store the commit as `version`).
  testDshIsNamedForItsPin = {
    expr = package.drvAttrs.name;
    expected = "deepseek-harness-${pin.version}";
  };

  # The baseline's preBuild exports, made static: commit from the pin, profile "official" as in
  # nixpkgs.
  testDshStampsThePinnedCommitAsOfficial = {
    expr = package.drvAttrs.preBuild;
    expected = ''
      export DSH_CLIENT_COMMIT_HASH="${pin.version}"
      export DSH_CLIENT_BUILD_PROFILE="official";
    '';
  };

  # The baseline installs checked: `dsh --version` runs in-store.
  testDshInstallsChecked = {
    expr = package.drvAttrs.doInstallCheck;
    expected = true;
  };

  # The command the package promises, and the pin it was built from: a fixed rev
  # (`strategy: none`), a source nar (`kind: nar`), and only the one system this flake's hosts
  # run.
  testDshNamesItsProgramAndPin = {
    expr = {
      mainProgram = package.meta.mainProgram;
      version = package.drvAttrs.version;
      inherit (pin) kind strategy;
      systems = pinMeta.pinnedSystems pin;
    };
    expected = {
      mainProgram = "dsh";
      inherit (pin) version;
      kind = "nar";
      strategy = "none";
      systems = ["x86_64-linux"];
    };
  };
}
