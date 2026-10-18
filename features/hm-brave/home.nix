{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.brave-browser;
  basePackage = pkgs.unstable.callPackage ./_package.nix {};

  bravePackage = config.lib.nixGL.wrapMesa basePackage;
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
    home.packages = [bravePackage];
    programs.chromium = {
      enable = true;
      package = bravePackage;
      commandLineArgs = lib.optional (cfg.passwordStore != null) "--password-store=${cfg.passwordStore}";
    };
    fonts.fontconfig.enable = true;
  };
}
