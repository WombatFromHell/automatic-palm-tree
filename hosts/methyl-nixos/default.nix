_: let
  username = "josh";

  myNixOS = let
    inherit username;
  in
    {
      pkgs,
      pkgsUnstable,
      ...
    }: {
      imports = [./hardware-configuration.nix];

      boot = {
        loader.systemd-boot.enable = true;
        loader.efi.canTouchEfiVariables = true;
        kernelPackages = pkgs.linuxPackages_latest;
        #kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest;
      };
      networking = {
        hostName = "methyl-nixos";
        networkmanager = {
          enable = true;
          wifi.backend = "iwd";
        };
        wireless.iwd = {
          enable = true; # mutually exclusive with wpa_supplicant
          settings = {
            IPv6.Enabled = true;
            Settings.AutoConnect = true;
          };
        };
      };

      security.rtkit.enable = true;
      services = {
        #xserver.videoDrivers = ["amdgpu"];
        displayManager.sddm.enable = true;
        desktopManager.plasma6.enable = true;
        xserver.xkb = {
          layout = "us";
          variant = "";
        };

        pulseaudio.enable = false;
        pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
          #jack.enable = true;
          #media-session.enable = true;
        };

        printing = {
          enable = true;
          drivers = [pkgs.brlaser];
        };
        lact.enable = true;
        tailscale.enable = true;
        flatpak.enable = true;
        openssh.enable = true;
      };

      hardware = {
        bluetooth.enable = true;
        graphics = {
          enable = true;
          enable32Bit = true; # For 32-bit apps/games
        };
        printers = {
          ensureDefaultPrinter = "HL2270DW";
          ensurePrinters = [
            {
              name = "HL2270DW";
              description = "Brother HL-2270DW";
              deviceUri = "lpd://192.168.1.10/queue";
              model = "drv:///brlaser.drv/br2270d.ppd";
              ppdOptions = {
                PageSize = "A4";
                Duplex = "None";
              };
            }
          ];
        };
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

      users.users.${username} = {
        isNormalUser = true;
        home = "/home/${username}";
        initialPassword = "changeme";
        extraGroups = [
          "input"
          "lp"
          "networkmanager"
          "wheel"
        ];
      };

      environment.systemPackages = with pkgs; [
        curl
        gamescope
        git
        helix
        python3
        steam-run
        vulkan-tools
        wget
      ];

      programs = {
        firefox.enable = true;
        appimage = {
          enable = true;
          binfmt = true;
        };
        nix-ld.enable = true;
        steam = {
          enable = true;
          package = pkgsUnstable.steam;
        };
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
  system = "x86_64-linux";
  inherit username;
  isNixOS = true;

  unfree = [
    "steam"
    "steam-run"
    "steam-unwrapped"
  ];

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
  ];

  modules = {
    home = [myHome];
    nixos = [myNixOS];
  };
}
