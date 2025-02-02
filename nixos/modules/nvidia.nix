{
  config,
  lib,
  pkgs,
  ...
}: let
  moduleName = "nvidia-support";
in {
  options."${moduleName}".enable = lib.mkEnableOption "User configured NVIDIA driver module";

  config = lib.mkIf config."${moduleName}".enable {
    services.xserver.videoDrivers = ["nvidia"];

    hardware = {
      graphics = {
        enable = true;
        extraPackages = with pkgs; [
          nvidia-vaapi-driver
        ];
      };

      # only for use with pre-25.11
      # opengl.enable = true;

      nvidia = {
        modesetting.enable = true;
        powerManagement.enable = true;
        open = true;
        nvidiaSettings = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;
      };
    };

    # enable nvidia-container-toolkit support (podman)
    virtualisation.docker.rootless.daemon.settings.features.cdi = true;

    environment.systemPackages = with pkgs; [
      nvtop-nvidia
      nvidia-container-toolkit
    ];

    # add a sudoers rule for 'nvidia-settings' so admins can use fan control support
    security.sudo = {
      extraRules = [
        {
          groups = ["wheel"];
          commands = [
            {
              command = "${config.hardware.nvidia.package.bin}/bin/nvidia-settings";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
    };
  };
}
