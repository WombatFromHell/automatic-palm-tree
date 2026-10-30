{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.nixgl;
in {
  # Home Manager's enum (modules/targets/generic-linux/nixgl.nix); tests/home.nix asserts the
  # wrapper set it builds stays exactly these names, so the two cannot drift apart.
  options.features.nixgl.wrapper = lib.mkOption {
    type = lib.types.enum ["mesa" "mesaPrime" "nvidia" "nvidiaPrime"];
    default = "mesa";
    description = ''
      Which nixGL wrapper Home Manager uses for GUI packages on a non-NixOS host. Intel Mesa is
      the default; a host with an Nvidia GPU sets nvidia, or nvidiaPrime for the offload/prime
      GPU. The Nvidia wrappers require the configuration to be built with --impure.
    '';
  };

  # nixGL supplies GL/EGL/drivers only where the host has none: on a NixOS host the system
  # provides them, so packages stays null and config.lib.nixGL.wrapGpu
  # (modules/defaults/home-manager.nix) is a no-op there. Setting it unconditionally would pull
  # foreign Mesa into a NixOS closure. defaultWrapper still follows the host's choice, which is
  # what makes Home Manager's own lib.nixGL.wrap pick the right driver set here.
  config.targets.genericLinux.nixGL = {
    packages = lib.mkIf (!config.flakeHost.isNixOS) pkgs.flakePackages.nixgl;
    defaultWrapper = cfg.wrapper;
  };
}
