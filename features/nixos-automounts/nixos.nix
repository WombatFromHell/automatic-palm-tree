{
  pkgs,
  fsLib,
  ...
}: let
  # Group that owns the CIFS shares. Files are group-rw, so anyone listed in `members`
  # below gets access; no uid is hardcoded, and `mount.cifs` resolves the name at mount time.
  group = "nas";
  members = ["josh"];

  credentials = "/etc/.smb-credentials";
  smb = share: "//192.168.1.153/${share}";

  base = {
    automount = true;
    mountConfig.TimeoutSec = 5;
  };
  common = ["nofail" "x-gvfs-show"];

  btrfs = fsLib.mkUnitMounts (base
    // {
      type = "btrfs";
      subvol = "@";
      skipIfMissing = true;
      options = common ++ ["noatime" "compress=zstd:3"];
    }) {
    "/mnt/data" = "/dev/disk/by-uuid/25dc01da-4cc4-4d5b-bca7-d11f74732d0c";
    "/mnt/linuxdata" = "/dev/disk/by-uuid/be63764a-f6bd-4687-aa07-9c7ddea97cc4";
  };

  cifs = fsLib.mkUnitMounts (base
    // {
      type = "cifs";
      options =
        common
        ++ [
          "rw"
          "credentials=${credentials}"
          "gid=${group}"
          "file_mode=0664"
          "dir_mode=0775"
          "iocharset=utf8"
        ];
      requires = ["network-online.target"];
      after = ["network-online.target"];
      unitConfig.ConditionPathExists = credentials;
    }) {
    "/mnt/Downloads" = smb "Downloads";
    "/mnt/FTPRoot" = smb "FTPRoot";
  };
in {
  environment.systemPackages = [pkgs.cifs-utils];

  users.groups.${group}.members = members;

  extraGroups = {filesystems = ["nas"];};

  systemd = fsLib.joinUnitMounts [btrfs cifs];
}
