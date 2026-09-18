{
  lib,
  config,
  ...
}: {
  options.features.syncthing.enable = lib.mkEnableOption "User-level Syncthing service" // {default = true;};

  config.networking.firewall = lib.mkIf config.features.syncthing.enable {
    allowedTCPPorts = [22000];
    allowedUDPPorts = [22000 21027];
  };
}
