{
  pkgs,
  pkgsUnstable,
  inputs,
  ...
}: let
  dmsPkg = pkgsUnstable.dms-shell;
  # dmsPkg = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  imports = [
    ./niri.nix
    ./niri-portals.nix
  ];

  environment.systemPackages = with pkgs; [
    pkgsUnstable.niri
    pkgsUnstable.dsearch
    kanshi
    kdePackages.qt6ct
    liberation_ttf
    noto-fonts
    xwayland-satellite
  ];

  security.polkit.enable = true;

  programs = {
    uwsm.enable = true;
    dms-shell = {
      enable = true;
      package = dmsPkg;
      quickshell.package = pkgsUnstable.quickshell;
    };
  };
}
