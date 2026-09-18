{
  pkgs,
  pkgsUnstable,
  config,
  lib,
  ...
}: {
  imports = [
    ./_niri.nix
    ./_niri-portals.nix
  ];

  config = lib.mkIf config.features.niri.enable {
    environment.systemPackages = with pkgs; [
      pkgsUnstable.niri
      pkgsUnstable.dsearch
      kdePackages.qt6ct
      liberation_ttf
      noto-fonts
      xwayland-satellite
    ];

    security.polkit.enable = true;

    programs.uwsm.enable = true;
  };
}
