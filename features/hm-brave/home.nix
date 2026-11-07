{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.brave-browser;
  basePackage = pkgs.unstable.callPackage ./_package.nix {};

  bravePackage = config.lib.nixGL.wrapGpu basePackage;
in {
  options.features.brave-browser = {
    enable = lib.mkEnableOption "Privacy-oriented browser for Desktop and Laptop, built on Chromium" // {default = true;};
    # On this side it decides nothing about the kernel: features/hm-brave/nixos.nix owns the
    # sysctl. Turning it off here only silences the activation hint below.
    harden.enable =
      lib.mkEnableOption "Yama ptrace hardening for Brave's sandbox"
      // {
        default = true;
      };
    passwordStore = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["basic" "gnome" "gnome-keyring" "gnome-libsecret" "kwallet5" "kwallet6"]);
      default = null;
      description = "Override Brave's --password-store backend; null lets it autodetect.";
    };
  };
  config = lib.mkIf cfg.enable {
    # programs.chromium installs cfg.finalPackage into home.packages itself, so adding
    # bravePackage here would put the same store path on PATH twice.
    programs.chromium = {
      enable = true;
      package = bravePackage;
      commandLineArgs = lib.optional (cfg.passwordStore != null) "--password-store=${cfg.passwordStore}";
    };
    fonts.fontconfig.enable = true;
    # Nothing here can set a kernel sysctl on a standalone host, so say the kernel is
    # unhardened — and only on a non-NixOS host, where the sysctl is ours to set, and only when
    # it actually is unhardened: cat is on activation's PATH via home.activationPackages.
    # mkIf on the *value*, not on the attrset: a config whose keys depend on `config` recurses.
    home.activation.bravePtraceHint = lib.mkIf (cfg.harden.enable && !config.flakeHost.isNixOS) (lib.hm.dag.entryAfter ["writeBoundary"] ''
      scope=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)
      if [ "$scope" != "1" ]; then
        echo "warning: hm-brave: kernel.yama.ptrace_scope is not 1 here ($scope - 0 means unrestricted, absent means the kernel has no Yama). NixOS hosts get it from features/hm-brave/nixos.nix; on this host set it yourself: sudo sysctl kernel.yama.ptrace_scope=1, or persist it in /etc/sysctl.d/60-yama.conf."
      fi
    '');
  };
}
