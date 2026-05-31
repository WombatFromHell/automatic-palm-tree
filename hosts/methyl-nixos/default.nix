_: let
  bootstrap = true; # set to false once flake is initialized (for caching)
  system = "x86_64-linux";
  username = "josh";
  isNixOS = true;

  myNixOS = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    imports = [./hardware-configuration.nix];

    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;
      # cachyos kernel only enabled if attr 'bootstrap = false;' set
      kernelPackages =
        if bootstrap
        then pkgs.linuxPackages_latest
        else pkgs.cachyosKernels.linuxPackages-cachyos-latest;
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
  inherit bootstrap system username isNixOS;

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
    "nixos-justnh"
  ];

  modules = {
    home = [myHome];
    nixos = [myNixOS];
  };
}
