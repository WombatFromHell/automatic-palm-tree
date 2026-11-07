# nix-unit attributes for features/hm-brave/nixos.nix: Yama hardening is a default, never a force.
# Nothing is built -- a bare module eval with the sysctl option stubbed.
#
# Priorities in this nixpkgs are inverted (lowest number wins): lib.mkForce 50, a plain assignment
# 100, lib.mkDefault 1000, mkOptionDefault 1500. The module writes 1100, so it fills the slot only
# when nobody else has set the key.
let
  s = import ./support.nix;
  inherit (s) lib;

  module = ../features/hm-brave/nixos.nix;

  # NixOS declares boot.kernel.sysctl; a bare lib.evalModules does not.
  sysctlStubs = {
    options.boot.kernel.sysctl = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.int lib.types.str);
      default = {};
    };
  };

  sysctl = enable: harden: extra:
    (s.bareEval [sysctlStubs module]
      ({
          features.brave-browser = {
            inherit enable;
            harden.enable = harden;
          };
        }
        // extra)
      {}).boot.kernel.sysctl;
in {
  testYamaIsOnWhenBraveIsEnabled = {
    expr = sysctl true true {};
    expected = {"kernel.yama.ptrace_scope" = 1;};
  };
  # The safety valve: turning harden off leaves the kernel alone, brave still installed.
  testHardenOffLeavesTheSysctlAlone = {
    expr = sysctl true false {};
    expected = {};
  };
  testBraveDisabledLeavesTheSysctlAlone = {
    expr = sysctl false true {};
    expected = {};
  };
  # Two higher-priority enablements must win, so a host or another module can set the key
  # without a "defined multiple times" error.
  testAnotherModulesMkDefaultWins = {
    expr = sysctl true true {
      boot.kernel.sysctl."kernel.yama.ptrace_scope" = lib.mkDefault 2;
    };
    expected = {"kernel.yama.ptrace_scope" = 2;};
  };
  testAHostsPlainAssignmentWins = {
    expr = sysctl true true {
      boot.kernel.sysctl."kernel.yama.ptrace_scope" = 0;
    };
    expected = {"kernel.yama.ptrace_scope" = 0;};
  };
}
