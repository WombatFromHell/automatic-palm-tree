{pkgs, ...}: {
  boot = {
    plymouth = {
      enable = true;
      theme = "nixos-bgrt";
      themePackages = with pkgs; [nixos-bgrt-plymouth];
    };
    kernelParams = [
      "quiet"
      "splash"
    ];
    initrd = {
      systemd.enable = true;
      kernelModules = [ "amdgpu" "virtio_gpu" ];
    };
  };
}
