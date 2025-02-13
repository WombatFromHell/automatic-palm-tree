{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };
  nixpkgs.config.allowUnfree = true;

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    kernelParams = ["amd_pstate=active"];
    # kernelPackages = pkgs.linuxPackages_latest;
    kernelPackages = pkgs.linuxPackages_cachyos;

    # set sane swappiness behavior
    kernel.sysctl = {
      "vm.swappiness" = 1;
      "vm.watermark_boost_factor" = 0;
      "kernel.split_lock_mitigate" = 0;
    };
  };

  security = {
    rtkit.enable = true;
    sudo.enable = true;
  };

  networking = {
    hostName = hostArgs.hostname;
    networkmanager.enable = true;
    firewall.enable = false;
  };

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

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    priority = 100;
    memoryPercent = 13;
  };

  # hold-over from 24.11 unstil 25.11 comes out
  # hardware.pulseaudio.enable = false;

  nvidia-support.enable = true;
  nvidia-support.cdi.enable = true;

  local-mounts.enable = true;

  services = {
    earlyoom.enable = true;

    xserver.enable = true;
    displayManager.sddm.enable = true;
    desktopManager.plasma6.enable = true;
    xserver.xkb = {
      layout = "us";
      variant = "";
    };

    #openssh.enable = true;

    printing = {
      enable = true;
      # provide the brother printer lpd's
      drivers = with pkgs; [brlaser];
    };

    # disabled until 25.11
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      wireplumber.enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    ananicy = {
      enable = true;
      package = pkgs.ananicy-cpp;
      rulesProvider = pkgs.ananicy-rules-cachyos;
      extraRules = [
        {
          "name" = "Dragon Age The Veilguard.exe";
          "type" = "Game";
        }
        {
          "name" = "TheGreatCircle.exe";
          "type" = "Game";
        }
      ];
    };

    flatpak.enable = true;
    # ollama.enable = true;
    # scx.enable = true;

    lightsout.enable = true;
    nvidia-pm.enable = true;
    sleepfix.enable = true;
    veridian-controller.enable = true;

    # use kyber as the default ioscheduler
    udev.extraRules = ''
      ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="kyber"
      ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
    '';
  };

  fonts.fontconfig.useEmbeddedBitmaps = true;

  environment.systemPackages = with pkgs; [
    lix
    cifs-utils
    wget
    curl
    neovim
    nh
    dive
    podman-tui
    podman-compose
    desktop-file-utils
  ];

  users.users.${user} = {
    isNormalUser = true;
    description = "${user}";
    uid = hostArgs.myuid;
    extraGroups = ["networkmanager" "wheel" "input" "i2c"];
    shell = pkgs.fish;
  };

  hardware = {
    bluetooth.enable = true;
    steam-hardware.enable = true;
  };

  # networking.firewall.allowedTCPPorts = [];
  # networking.firewall.allowedUDPPorts = [];
  # networking.firewall.enable = false;

  programs = {
    fish.enable = true;
    steam.enable = true;
    nix-ld.enable = true;
    dconf.enable = true;
    appimage = {
      enable = true;
      binfmt = true;
    };

    nh = {
      enable = true;
      clean.enable = true;
      clean.extraArgs = "--keep-since 7d --keep 5";
      flake = "/home/${user}/.dotfiles/nix";
    };

    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
      pinentryPackage = pkgs.pinentry-all;
    };
  };

  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  systemd.services.flatpak-repo = {
    wantedBy = ["multi-user.target"];
    path = [pkgs.flatpak];
    script = ''
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    '';
  };

  system.stateVersion = "24.11";
}
