# nix-unit attributes for features/hm-piweb/_package.nix: the pi-web build from the pinned commit.
# Only `drvAttrs` keys are forced, never `outPath` — no build, no npm fetch (same reasoning as
# tests/dsh.nix).
let
  s = import ./support.nix;
  inherit (s) lib pkgs;
  # Read straight from lib/pin-meta.nix, like tests/pins.nix, so the pin's own contract is
  # what's checked, not the copy the package-set overlay hands out.
  pinMeta = import ../lib/pin-meta.nix {inherit lib;};

  # Invoked the way production does: pinMeta comes from the loader's package set.
  package = pkgs.callPackage ../features/hm-piweb/_package.nix {};
  pin = builtins.fromJSON (builtins.readFile ../features/hm-piweb/metadata.json);
in {
  # A nar pin stores the commit as `version`, so the derivation is named for the commit and not for
  # the v-prefixed tag the release page calls it.
  testPiWebIsNamedForItsPin = {
    expr = package.drvAttrs.name;
    expected = "pi-web-${pin.version}";
  };

  # The build boots the server and polls /health, so the install check is the proof it runs.
  testPiWebInstallsChecked = {
    expr = package.drvAttrs.doInstallCheck;
    expected = true;
  };

  # The command the package promises, and the pin it was built from: a fixed rev
  # (`strategy: none`), a source nar (`kind: nar`), and only the one system this flake's hosts run.
  testPiWebNamesItsProgramAndPin = {
    expr = {
      mainProgram = package.meta.mainProgram;
      version = package.drvAttrs.version;
      inherit (pin) kind strategy;
      systems = pinMeta.pinnedSystems pin;
    };
    expected = {
      mainProgram = "pi-web";
      inherit (pin) version;
      kind = "nar";
      strategy = "none";
      systems = ["x86_64-linux"];
    };
  };

  # The runtime node is the shared slim one every host gets, named in both the install phase and the
  # launcher rewrite; stdenv's shebang patching is off so npm's hooks cannot point it back at the
  # build-time node.
  testPiWebRunsOnTheSharedSlimNode = {
    expr = {
      # splitString, not hasInfix: Nix refuses a store path inside a regex pattern, and hasInfix
      # compiles one.
      namesRuntimeNode = lib.elem "${pkgs.nodejs-slim_24}/bin/node" (lib.splitString "\"" package.drvAttrs.installPhase);
      dontPatchShebangs = package.drvAttrs.dontPatchShebangs;
    };
    expected = {
      namesRuntimeNode = true;
      dontPatchShebangs = true;
    };
  };
}
