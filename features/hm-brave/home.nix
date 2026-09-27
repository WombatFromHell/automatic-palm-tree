{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.brave-browser;
  brave-custom = pkgs.callPackage ./_package.nix {};
  basePackage = brave-custom;

  bravePackage =
    if config.lib ? nixGL
    then config.lib.nixGL.wrap basePackage
    else basePackage;
in {
  options.features.brave-browser = {
    enable = lib.mkEnableOption "Privacy-oriented browser for Desktop and Laptop, built on Chromium" // {default = true;};
    passwordStore = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["basic" "gnome" "gnome-keyring" "gnome-libsecret" "kwallet5" "kwallet6"]);
      default = null;
      description = "Override Brave's --password-store backend; null lets it autodetect.";
    };
  };
  config = lib.mkIf cfg.enable {
    programs.chromium = {
      enable = true;
      package = bravePackage;
      commandLineArgs = lib.optional (cfg.passwordStore != null) "--password-store=${cfg.passwordStore}";
    };
  };
}
