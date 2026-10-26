{...}: {
  imports = [./hardware-configuration.nix];

  hardware = {
    opengl.enable = true;
    graphics.enable = true;
  };
  services.openssh.enable = true;
  features = {
    qemu = {
      enable = false;
      spiceAgent.enable = true;
    };
    niri.niriSpicy.enable = true;
  };
}
