{
  config,
  lib,
  pkgs,
  hostArgs,
  ...
}: let
  moduleName = "nvidia-support";

  mainConfig = lib.mkIf config."${moduleName}".enable {
    services.xserver.videoDrivers = ["nvidia"];

    hardware = {
      graphics.enable = true;
      nvidia = {
        modesetting.enable = true;
        powerManagement.enable = true;
        open = true;
        nvidiaSettings = true;
        videoAcceleration = true;
        package = config.boot.kernelPackages.nvidiaPackages.beta;
      };
    };

    environment.systemPackages = with pkgs; [
      nvtopPackages.nvidia
    ];

    environment.sessionVariables = {
      NVD_BACKEND = "direct";
      MOZ_DISABLE_RDD_SANDBOX = "1";
      LIBVA_DRIVER_NAME = "nvidia";
    };

    security.sudo = {
      # '!requiretty' is necessary for 'veridian-controller to function'
      extraConfig = ''
        Defaults !requiretty
      '';
      # add a sudoers rule for 'nvidia-settings' so admins can use fan control support
      # extraRules = [
      #   {
      #     # groups = ["wheel"];
      #     users = ["${hostArgs.username}"];
      #     commands = [
      #       {
      #         command = "${config.hardware.nvidia.package.settings}/bin/nvidia-settings";
      #         options = ["NOPASSWD" "SETENV"];
      #       }
      #     ];
      #   }
      # ];
    };
  };

  cdiConfig = lib.mkIf (config."${moduleName}".cdi.enable
    && config.virtualisation.podman.enable) {
    environment.systemPackages = with pkgs; [
      nvidia-container-toolkit
    ];

    # enable nvidia-container-toolkit support
    hardware.nvidia-container-toolkit.enable = true;

    # Create CDI directory
    systemd.tmpfiles.rules = [
      "d /etc/cdi 0755 root root -"
    ];

    # Generate CDI spec on boot
    systemd.services.generate-nvidia-cdi-spec = {
      wantedBy = ["multi-user.target"];
      after = ["nvidia-container-toolkit.service"];
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.nvidia-container-toolkit}/bin/nvidia-ctk cdi generate --output /etc/cdi/nvidia.yaml
        chmod 644 /etc/cdi/nvidia.yaml
      '';
    };
  };
in {
  options = {
    "${moduleName}" = {
      enable = lib.mkEnableOption "Enable user configured NVIDIA driver customizations";
      cdi.enable = lib.mkEnableOption "Enable NVIDIA CDI support for rootless containers";
    };
  };

  config = lib.mkMerge [
    mainConfig
    cdiConfig
  ];
}
