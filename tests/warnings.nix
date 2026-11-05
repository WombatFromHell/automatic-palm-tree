# nix-unit attributes for modules/warnings-gate.nix: any configuration warning must fail a
# build. A bare module eval — no NixOS, no build, and it never forces a real host's config, so
# the ~2GB that forcing config.warnings costs on a host is not paid here.
let
  core = import ./support.nix;
  inherit (core) lib flakeHostStub desktopStubs failingAssertions hostsAt;
  featurePaths = core.features;

  eval = warnings: core.bareEval [../modules/warnings-gate.nix] {inherit warnings;} {};

  # A fixture host that asks for both desktop environments: GDM owns the login screen, so the
  # Plasma session is the thing the greeter loses. Bare eval - no NixOS, no build.
  # gnome.nix hands a package to environment.systemPackages; the stub keeps that check phase
  # satisfied without instantiating anything.
  desktop = features:
    core.bareEval
      [flakeHostStub desktopStubs ../modules/warnings-gate.nix]
      {imports = featurePaths.resolveFeaturePaths features "nixos";}
      {pkgs = {gnome-tweaks = {name = "gnome-tweaks";};};};

  bothDesktops = (hostsAt ./fixtures).discoveredHosts.desktophost.features;
  bothWarnings = (desktop bothDesktops).warnings;
  # The message is what a failing build prints, so it has to carry the warning verbatim.
  oneWarning = failingAssertions (eval ["flakeCache: \"https://x\" is required"]);
  oneWarningLines = lib.splitString "\n" (builtins.head oneWarning).message;
  twoWarnings = failingAssertions (eval ["first warning" "second warning"]);
in
  {
    testFixtureHostAsksForBothDesktops = {
      expr = bothDesktops;
      expected = ["nixos-kde" "nixos-gnome"];
    };
    testBothDesktopsWarnOnce = {
      expr = builtins.length bothWarnings;
      expected = 1;
    };
    # Enabling both warns which session the greeter drops.
    testBothDesktopsWarnNamesPlasma = {
      expr = lib.hasInfix "Plasma" (builtins.head bothWarnings);
      expected = true;
    };
    testKdeAloneWarnsNothing = {
      expr = (desktop ["nixos-kde"]).warnings;
      expected = [];
    };
    testGnomeAloneWarnsNothing = {
      expr = (desktop ["nixos-gnome"]).warnings;
      expected = [];
    };

    testNoWarningsLeavesGateAssertionTrue = {
      expr = failingAssertions (eval []);
      expected = [];
    };
    testOneWarningFailsOneAssertion = {
      expr = builtins.length oneWarning;
      expected = 1;
    };
    testWarningMessageStartsWithTheHeader = {
      expr = builtins.head oneWarningLines;
      expected = "configuration warnings:";
    };
    testWarningMessageCarriesTheWarning = {
      expr = lib.hasPrefix "flakeCache: \"https://x\" is required" (builtins.elemAt oneWarningLines 1);
      expected = true;
    };
    # Every warning is listed, not just the first.
    testManyWarningsFailOneAssertion = {
      expr = builtins.length twoWarnings;
      expected = 1;
    };
    testManyWarningsListTheLast = {
      expr = lib.hasSuffix "second warning" (builtins.head twoWarnings).message;
      expected = true;
    };
  }
