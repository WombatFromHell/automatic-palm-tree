# The warnings gate (modules/warnings-gate.nix): any configuration warning must fail a build.
# A bare module eval — no NixOS, no build, and it never forces a real host's config, so the
# ~2GB that forcing `config.warnings` costs on a host is not paid here.
let
  core = import ./support.nix;
  inherit (core) lib ck suite assertWarnStubs flakeHostStub desktopStubs failingAssertions hostsAt;
  featurePaths = core.features;

  eval = warnings:
    (lib.evalModules {
      modules = [
        assertWarnStubs
        ../modules/warnings-gate.nix
        {inherit warnings;}
      ];
    }).config;

  # A fixture host that asks for both desktop environments: GDM owns the login screen,
  # so the Plasma session is the thing the greeter loses. Bare eval - no NixOS, no build.
  desktop = features:
    (lib.evalModules {
      modules = [
        assertWarnStubs
        flakeHostStub
        desktopStubs
        ../modules/warnings-gate.nix
        {imports = featurePaths.resolveFeaturePaths features "nixos";}
      ];
      # gnome.nix hands a package to environment.systemPackages; the stub keeps that
      # check phase satisfied without instantiating anything.
      specialArgs = {pkgs = {gnome-tweaks = {name = "gnome-tweaks";};};};
    }).config;

  bothDesktops = (hostsAt ./fixtures).discoveredHosts.desktophost.features;

in
  suite "warnings" [
    # --- desktop session drop ------------------------------------------------
    (ck "the fixture host asks for both desktop environments"
      (bothDesktops == ["nixos-kde" "nixos-gnome"]))

    (ck "enabling both warns which session the greeter drops"
      (let
        w = (desktop bothDesktops).warnings;
      in
        (builtins.length w == 1) && (lib.hasInfix "Plasma" (builtins.head w))))

    (ck "one desktop alone warns nothing"
      ((desktop ["nixos-kde"]).warnings == [] && (desktop ["nixos-gnome"]).warnings == []))

    # --- the gate itself -----------------------------------------------------
    (ck "no warnings leaves the gate's assertion true" (failingAssertions (eval []) == []))

    # The message is what a failing build prints, so it has to carry the warning verbatim.
    (ck "one warning fails the assertion and its message names it"
      (let
        failed = failingAssertions (eval ["flakeCache: \"https://x\" is required"]);
        lines = lib.splitString "\n" (builtins.head failed).message;
      in
        (builtins.length failed == 1)
        && (lib.head lines == "configuration warnings:")
        && (lib.hasPrefix "flakeCache: \"https://x\" is required" (lib.elemAt lines 1))))

    (ck "every warning is listed, not just the first"
      (let
        failed = failingAssertions (eval ["first warning" "second warning"]);
      in
        (builtins.length failed == 1)
        && (lib.hasSuffix "second warning" (builtins.head failed).message)))
  ]
