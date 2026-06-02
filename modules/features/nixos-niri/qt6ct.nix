{
  pkgs,
  lib,
  config,
  ...
}: let
  qt6ctConfFile = ./qt6ct.conf;
in {
  config = lib.mkIf config.features.niri.enable {
    environment = {
      systemPackages = with pkgs; [
        kdePackages.qt6ct
      ];

      etc."xdg/qt6ct/qt6ct.conf".source = qt6ctConfFile;
    };
  };
}
