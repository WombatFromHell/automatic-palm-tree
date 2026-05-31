{
  pkgs,
  pkgsUnstable,
  ...
}: {
  unfree = [
    "steam"
    "steam-run"
    "steam-unwrapped"
  ];

  environment.systemPackages = with pkgs; [
    gamescope
    steam-run
    vulkan-tools
  ];

  programs = {
    steam = {
      enable = true;
      package = pkgsUnstable.steam;
    };
  };

  services.lact.enable = true;

  hardware = {
    bluetooth.enable = true;
    graphics = {
      enable = true;
      enable32Bit = true; # For 32-bit apps/games
    };
  };
}
