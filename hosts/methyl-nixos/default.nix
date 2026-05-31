_: let
  system = "x86_64-linux";
  username = "josh";
  isNixOS = true;

  myNixOS = {
    pkgs,
    pkgsUnstable,
    ...
  }: let
    inherit username;
  in {
    imports = [./hardware-configuration.nix];

    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;
      kernelPackages = pkgs.linuxPackages_latest;
      # uncomment the cachyos kernel after initial deployment (for caching)
      #kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest;
    };
    networking.hostName = "methyl-nixos";

    # for debugging purposes
    services.openssh.enable = true;

    users.users.${username} = {
      isNormalUser = true;
      home = "/home/${username}";
      extraGroups = [
        "input"
        "lp"
        "networkmanager"
        "wheel"
      ];
    };
  };

  myHome = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    home.packages = with pkgsUnstable; [
      khal
      libqalculate
      trash-cli
      yt-dlp
    ];

    services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
  };
in {
  inherit system username isNixOS;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    #
    "nixos-base"
    "nixos-audio"
    "nixos-network"
    "nixos-kde"
    "nixos-print"
    "nixos-gaming"
  ];

  modules = {
    home = [myHome];
    nixos = [myNixOS];
  };
}
