{fsLib, ...}: let
  # The layout terraform.sh reproduces from ./terraform.json (ADR-b77ec913151f): it writes the gpt
  # table, formats the labelled partitions and creates the subvolume tree, so the labels it mkfs
  # writes are the device names these mounts name and the options it mounts with are ours
  # (ADR-62773e12d275). Reading the recipe at eval is what keeps a mount from naming a device the
  # run will not create.
  mounts = fsLib.mountsFromRecipe (builtins.fromJSON (builtins.readFile ./terraform.json));
in {
  imports = [./hardware-configuration.nix];

  hardware.graphics.enable = true;
  services.openssh.enable = true;
  features = {
    qemu = {
      enable = false;
      spiceAgent.enable = true;
    };
  };

  fileSystems =
    mounts
    // fsLib.mkMounts mounts."/"
    {
      "/" = {subvol = "@";};
      "/home" = {subvol = "@home";};
      "/nix" = {subvol = "@nix";};
      # Boot logging reads /var/log before the root filesystem switch, so it mounts early.
      "/var/log" = {
        subvol = "@log";
        neededForBoot = true;
      };
      "/var/cache" = {subvol = "@cache";};
      "/var/lib/swap" = {subvol = "@swap";};
      "/.snapshots" = {subvol = "@snapshots";};
    };
}
