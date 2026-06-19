{
  lib,
  config,
  ...
}: {
  options.features.syncthing.enable = lib.mkEnableOption "User-level Syncthing service";

  config.services.syncthing = lib.mkIf config.features.syncthing.enable {
    enable = true;
  };
}
