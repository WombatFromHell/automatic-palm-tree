{fsLib, ...}: {
  imports = [./hardware-configuration.nix];

  hardware.graphics.enable = true;
  services.openssh.enable = true;
  features = {
    qemu = {
      enable = false;
      spiceAgent.enable = true;
    };
    niri.niriSpicy.enable = true;
  };

  # ── the mounts the layout terraform.sh reproduces from ./terraform.json ──
  # terraform.sh owns the drive on this host (ADR-b77ec913151f): it writes the gpt table, formats
  # the labelled partitions and creates the subvolume tree, so the labels it mkfs writes are the
  # device names these mounts name. The subvolume tree is the one this host has always used, and
  # the options are the ones terraform.sh mounts with (ADR-3d23b16441b6).
  fileSystems =
    fsLib.mkMounts {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = ["noatime" "compress=zstd"];
    }
    {
      "/" = {subvol = "@";};
      "/home" = {subvol = "@home";};
      "/nix" = {subvol = "@nix";};
      # Boot logging reads /var/log before the root filesystem switch, so it mounts early.
      "/var/log" = {subvol = "@log"; neededForBoot = true;};
      "/var/cache" = {subvol = "@cache";};
      "/var/lib/swap" = {subvol = "@swap";};
      "/.snapshots" = {subvol = "@snapshots";};
    }
    // {
      "/boot" = {
        device = "/dev/disk/by-label/boot";
        fsType = "vfat";
        options = ["fmask=0077" "dmask=0077"];
      };
    };
}
