{
  pkgs,
  pkgsUnstable,
  ...
}: let
  nscb = pkgs.callPackage ./_nscb_pkg.nix {};
  protonfetcher = pkgs.callPackage ./_protonfetcher_pkg.nix {};
in {
  boot.kernelParams = [
    "split_lock_detect=off"
    "amdgpu.ppfeaturemask=0xfffd7fff"
    "amdgpu.dcdebugmask=0x410"
    "amdgpu.lockup_timeout=100000"
    "amdgpu.runpm=0"
    "amdgpu.aspm=0"
    "amdgpu.gpu_recovery=1"
  ];

  environment.systemPackages = with pkgs; [
    nscb
    protonfetcher
    #
    gamescope
    pkgsUnstable.mesa
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
