{
  lib,
  pkgs,
  config,
  ...
}: let
  # Feature-declared groups are host-wide, so read them once instead of per user.
  featureExtraGroups = lib.concatLists (lib.attrValues config.extraGroups);
in {
  system.stateVersion = "25.11";
  networking.hostName = lib.mkDefault config.flakeHost.name;
  programs.fish.enable = lib.mkDefault true;
  # Substitute when a cache serves a path, build it ourselves only when it does not
  # (modules/caches.nix). Daemon behaviour is machine-wide, so it lives in the NixOS defaults
  # rather than in the registry module, which is imported into the Home Manager namespace too.
  nix.extraOptions = "fallback = true";
  # 1100 sits *below* lib.mkDefault (1000), so a kernel feature (nixos-kait2en, nixos-cachyos)
  # wins by mkDefault, while a host's plain assignment (priority 100) still pins a kernel.
  boot.kernelPackages = lib.mkOverride 1100 pkgs.linuxPackages_latest;

  users.users = lib.genAttrs config.flakeHost.osUsernames (username: {
    isNormalUser = true;
    home = "/home/${username}";
    shell = lib.mkOverride 50 pkgs.fish;
    # One admin branch: wheel plus whatever the enabled features need.
    extraGroups =
      ["networkmanager"]
      ++ lib.optionals (lib.elem username config.flakeHost.adminUsernames) (["wheel"] ++ featureExtraGroups);
  });
}
