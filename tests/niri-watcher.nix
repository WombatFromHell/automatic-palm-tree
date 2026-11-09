# nix-unit attributes for features/nixos-niri/_wl-watcher.nix: which GPU family of nvtop the
# watcher installs is the host's choice, and the default is the one an AMD install build can carry.
# Bare module eval -- nothing is built. The unit's ExecStart wiring is asserted on the real hosts in
# tests/configs.nix, so only the package list is stubbed here.
let
  s = import ./support.nix;
  inherit (s) lib;

  module = ../features/nixos-niri/_wl-watcher.nix;

  # Home Manager declares home.packages and systemd.user.services; a bare lib.evalModules declares
  # neither. The unit's ExecStart wiring is asserted on the real hosts in tests/configs.nix, so these
  # stubs exist only so the module can write them.
  hmStubs = {
    options.home.packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
    };
    options.systemd.user.services = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {};
    };
  };

  watcher = extra:
    (s.bareEval [hmStubs module]
      {
        features.niri.wl-watcher = {
          enable = true;
        }
        // extra;
      }
      {inherit (s) pkgs;})
    .home.packages;

  # Every nvtop variant reports the same name and version, so the variant's identity is the
  # derivation itself. Parenthesised: `f x.y` parses as `f (x.y)` in Nix.
  nvtop = ps: lib.head (s.pkgNamed ps "nvtop");
in {
  # `nvtopPackages.full` builds every GPU family and its inputs carry CUDA (`cuda-merged`), which
  # fails the install build on methyl -- so the default is the AMD family, not full.
  testDefaultInstallsTheAmdVariant = {
    expr = (nvtop (watcher {})).outPath == s.pkgs.nvtopPackages.amd.outPath;
    expected = true;
  };
  # The override has to reach the package, not merely type-check.
  testAHostsVariantReachesThePackage = {
    expr = (nvtop (watcher {nvtopVariant = "nvidia";})).outPath == s.pkgs.nvtopPackages.nvidia.outPath;
    expected = true;
  };
  # The variant names come from the package set filtered to derivations: `recurseForDerivations`
  # is a flag nixpkgs puts in that attrset, not a package a host can install.
  testVariantIsCheckedAgainstThePackageSet = {
    expr = (nvtop (watcher {nvtopVariant = "recurseForDerivations";})).outPath;
    expectedError = {
      msg = "nvtopVariant' is not of type";
    };
  };
  # A host enabling the niri feature without the watcher installs nothing for it.
  testWatcherOffInstallsNoPackages = {
    expr =
      (s.bareEval [hmStubs module]
        {features.niri.wl-watcher.enable = false;}
        {inherit (s) pkgs;})
      .home.packages;
    expected = [];
  };
}
