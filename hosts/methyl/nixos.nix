{fsLib, ...}: let
  # The layout terraform.sh reproduces from ./terraform.json (ADR-b77ec913151f). Reading the recipe at
  # eval is what keeps a mount from naming a device the run will not create: terraform.sh adopts the
  # ESP that already answers `boot` and appends the ext4 root into free space, and the labels it mkfs
  # writes are exactly the device names these mounts name (ADR-62773e12d275).
  #
  # The root entry declares no options, so NixOS still adds `x-initrd.mount` to `/` itself; terraform.sh
  # mounts it with its own ext4 `noatime` fallback while staging the store.
  mounts = fsLib.mountsFromRecipe (builtins.fromJSON (builtins.readFile ./terraform.json));
in {
  imports = [
    ./hardware-configuration.nix
  ];

  fileSystems = mounts;
}
