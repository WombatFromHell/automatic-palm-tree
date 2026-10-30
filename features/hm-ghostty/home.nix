{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.ghostty;
  # pinMeta is in both package sets, so this reads the stable set; the pin, not the
  # nixpkgs rev, decides which Ghostty lands here.
  basePackage = pkgs.callPackage ./_package.nix {};

  # The extracted AppDir carries its own GL/EGL/gbm stack, but the *drivers* come
  # from the host: on a non-NixOS host that is nixGL, on NixOS the wrapper is a
  # no-op (see modules/defaults/home-manager.nix).
  ghosttyPackage = config.lib.nixGL.wrapGpu basePackage;
in {
  options.features.ghostty.enable =
    lib.mkEnableOption "Ghostty terminal emulator, packaged from the pkgforge AppImage"
    // {
      default = true;
    };

  config = lib.mkIf cfg.enable {
    programs.ghostty = {
      enable = true;
      package = ghosttyPackage;
    };
    fonts.fontconfig.enable = true;
  };
}
