{
  config,
  lib,
  hostConfig,
  ...
}: let
  hasPodmanUser =
    builtins.any
    (username: builtins.elem "podman" (config.users.users.${username}.extraGroups or []))
    hostConfig.osUsernames;
in {
  config = {
    warnings =
      lib.optional (!hasPodmanUser)
      ("Podman is enabled but no user in osUsernames has the 'podman' extra group. "
        + "Add 'podman' to users.users.<name>.extraGroups on the host.");

    virtualisation = {
      containers.enable = true;
      podman = {
        enable = true;
        dockerCompat = true;
        dockerSocket.enable = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };
  };
}
