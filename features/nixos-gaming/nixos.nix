{pkgs, ...}: let
  nscb = pkgs.callPackage ./_nscb_pkg.nix {};
  protonfetcher = pkgs.callPackage ./_protonfetcher_pkg.nix {};
in {
  boot.kernelParams = [
    "clearcpuid=514"
    "split_lock_detect=off"
    "amdgpu.ppfeaturemask=0xfff7ffff"
  ];

  environment.systemPackages = with pkgs; [
    nscb
    protonfetcher
    #
    gamescope
    pkgs.unstable.mesa
    protonplus
    steam-run
    vulkan-tools
  ];

  programs = {
    steam.enable = true;
  };

  services.lact.enable = true;

  hardware = {
    bluetooth.enable = true;
    graphics = {
      enable = true;
      enable32Bit = true; # For 32-bit apps/games
    };
    steam-hardware.enable = true;
  };
}
