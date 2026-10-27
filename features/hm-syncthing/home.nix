{
  lib,
  config,
  ...
}: let
  cfg = config.features.syncthing;
in {
  options.features.syncthing.enable = lib.mkEnableOption "User-level Syncthing service" // {default = true;};

  config.services.syncthing.enable = cfg.enable;
}
