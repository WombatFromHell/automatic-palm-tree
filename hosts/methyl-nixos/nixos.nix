{lib, ...}: let
  # The options every subvolume of the shared btrfs root carries, as fsLib's mkMounts gave them.
  btrfsOpts = ["noatime" "compress=zstd"];
in {
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

  # ── the disk layout, in place of the generated mkMounts block ──
  # disko owns `fileSystems` on this host (ADR-eaca61b8); the subvolume tree is the one the host
  # has always used. `flakeHost.ownsWholeDisk` is what lets the gpt table partition the drive — a
  # VM drive with nothing else on it. Every create/format/mount step is guarded by `blkid` or
  # `findmnt`, so re-running the layout on an installed disk adopts what is already there.
  # The drive is the Apple virtualization backend's NVMe disk (/dev/nvme0n1), not virtio /dev/vda.
  disko.devices.disk.nvme0n1 = {
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        esp = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountOptions = ["fmask=0077" "dmask=0077"];
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            # `-f` so mkfs.btrfs does not refuse a device that still holds an old signature.
            extraArgs = ["-f"];
            subvolumes = {
              "@" = {
                mountpoint = "/";
                mountOptions = btrfsOpts;
              };
              "@home" = {
                mountpoint = "/home";
                mountOptions = btrfsOpts;
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = btrfsOpts;
              };
              "@log" = {
                mountpoint = "/var/log";
                mountOptions = btrfsOpts;
              };
              "@cache" = {
                mountpoint = "/var/cache";
                mountOptions = btrfsOpts;
              };
              "@swap" = {
                mountpoint = "/var/lib/swap";
                mountOptions = btrfsOpts;
              };
              "@snapshots" = {
                mountpoint = "/.snapshots";
                mountOptions = btrfsOpts;
              };
            };
          };
        };
      };
    };
  };

  # disko's btrfs type has no `neededForBoot`, and boot logging still needs /var/log mounted early.
  fileSystems."/var/log".neededForBoot = lib.mkForce true;
}
