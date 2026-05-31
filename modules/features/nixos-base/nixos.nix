{pkgs, ...}: {
  time.timeZone = "America/Denver";

  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    helix
    python3
    wget
  ];

  programs = {
    firefox.enable = true;
    appimage = {
      enable = true;
      binfmt = true;
    };
    nix-ld.enable = true;
  };

  services = {
    tailscale.enable = true;
    flatpak.enable = true;
  };
}
