# NixOS side of the Brave feature: Brave's Chromium sandbox is stronger when Yama restricts
# ptrace to descendants, so the feature asks for that sysctl. A standalone host has no kernel to
# configure here, so features/hm-brave/home.nix prints a hint instead.
#
# The option namespace is separate from Home Manager's, so `enable` is declared again — the same
# convention as features/hm-syncthing/nixos.nix.
{
  lib,
  config,
  ...
}: let
  cfg = config.features.brave-browser;
in {
  options.features.brave-browser = {
    enable =
      lib.mkEnableOption "Privacy-oriented browser for Desktop and Laptop, built on Chromium"
      // {
        default = true;
      };
    harden.enable =
      lib.mkEnableOption "Yama ptrace hardening for Brave's sandbox"
      // {
        default = true;
      };
  };

  # 1100 sits *below* lib.mkDefault (1000) — priorities are inverted, lowest number wins — so any
  # other enablement of this key (another module's mkDefault, a host's plain assignment, mkForce)
  # takes the slot instead of colliding with us. We only fill it when nobody set it.
  config = lib.mkIf (cfg.enable && cfg.harden.enable) {
    boot.kernel.sysctl."kernel.yama.ptrace_scope" = lib.mkOverride 1100 1;
  };
}
