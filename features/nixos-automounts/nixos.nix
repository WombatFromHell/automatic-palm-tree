{
  pkgs,
  fsLib,
  ...
}: let
  # ponytail: systemd mount units use their own `options` string, so fsLib.mkMounts
  # (fileSystems-shaped) cannot cover them; fsLib.mkUnitMounts covers the unit shape.
  # `compress=zstd:3` here intentionally differs from the zstd root mounts.
  # Upgrade path: share one options string if they ever must match.
  btrfs =
    fsLib.mkUnitMounts {
      type = "btrfs";
      options = [
        "noatime"
        "compress=zstd:3"
        "nofail"
        "x-gvfs-show"
        "x-systemd.mount-timeout=5"
      ];
    } {
      "/mnt/data" = {
        what = "/dev/disk/by-uuid/25dc01da-4cc4-4d5b-bca7-d11f74732d0c";
        subvol = "@";
        automount = true;
      };
      "/mnt/linuxdata" = {
        what = "/dev/disk/by-uuid/be63764a-f6bd-4687-aa07-9c7ddea97cc4";
        subvol = "@";
        automount = true;
      };
    };

  cifs =
    fsLib.mkUnitMounts {
      type = "cifs";
      options = [
        "rw"
        "credentials=/etc/.smb-credentials"
        "uid=1000"
        "gid=1000"
        "iocharset=utf8"
        "file_mode=0644"
        "dir_mode=0755"
        "x-systemd.mount-timeout=5"
        "x-gvfs-show"
        "nofail"
      ];
      requires = ["network-online.target"];
      after = ["network-online.target"];
    } {
      "/mnt/Downloads" = {
        what = "//192.168.1.153/Downloads";
        automount = true;
      };
      "/mnt/FTPRoot" = {
        what = "//192.168.1.153/FTPRoot";
        automount = true;
      };
    };
in {
  environment.systemPackages = with pkgs; [cifs-utils];

  systemd = {
    mounts = btrfs.mounts ++ cifs.mounts;
    automounts = btrfs.automounts ++ cifs.automounts;

    tmpfiles.rules = [
      "d /mnt/data 0755 0 0 -"
      "d /mnt/linuxdata 0755 0 0 -"
      "d /mnt/Downloads 0755 1000 1000 -"
      "d /mnt/FTPRoot 0755 1000 1000 -"
    ];
  };
}
