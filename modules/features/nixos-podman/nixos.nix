{
  config,
  lib,
  ...
}: let
  cfg = config.features.podman;
in {
  options.features.podman = {
    enableUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The username to add to the podman group (null for no user)";
    };
  };

  config = lib.mkMerge [
    {
      virtualisation = {
        containers.enable = true;
        podman = {
          enable = true;
          dockerCompat = true;
          dockerSocket.enable = true;
          defaultNetwork.settings.dns_enabled = true;
        };
      };
    }

    # Only add the user to the group if enableUser is defined
    (lib.mkIf (cfg.enableUser != null) {
      users.users.${cfg.enableUser}.extraGroups = ["podman"];
    })
  ];
}
