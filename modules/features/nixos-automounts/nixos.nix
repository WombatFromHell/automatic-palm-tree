{pkgs, ...}: let
  btrfsMountPair = {
    uuid,
    where,
  }: let
    unitName = builtins.replaceStrings ["/"] ["-"] (builtins.substring 1 (builtins.stringLength where - 1) where);
  in {
    mount = {
      description = "Mount for ${where}";
      type = "btrfs";
      what = "/dev/disk/by-uuid/${uuid}";
      inherit where;
      options = "noatime,compress=zstd:3,subvol=@,nofail,x-gvfs-show,x-systemd.mount-timeout=5";
      requires = ["${unitName}.automount"];
      after = ["${unitName}.automount"];
    };
    automount = {
      description = "Automount for ${where}";
      inherit where;
      wantedBy = ["multi-user.target"];
    };
  };

  cifsMountPair = {
    share,
    where,
  }: {
    mount = {
      description = "Mount for ${share}";
      type = "cifs";
      what = "//192.168.1.153/${share}";
      inherit where;
      options = "rw,credentials=/etc/.smb-credentials,uid=1000,gid=1000,iocharset=utf8,file_mode=0644,dir_mode=0755,x-systemd.mount-timeout=5,x-gvfs-show,nofail";
      requires = ["network-online.target"];
      after = ["network-online.target"];
    };
    automount = {
      description = "Automount for ${share}";
      inherit where;
      wantedBy = ["multi-user.target"];
      requires = ["network-online.target"];
      after = ["network-online.target"];
    };
  };

  mountPairs = [
    (btrfsMountPair {
      uuid = "25dc01da-4cc4-4d5b-bca7-d11f74732d0c";
      where = "/mnt/data";
    })
    (btrfsMountPair {
      uuid = "be63764a-f6bd-4687-aa07-9c7ddea97cc4";
      where = "/mnt/linuxdata";
    })
    (cifsMountPair {
      share = "Downloads";
      where = "/mnt/Downloads";
    })
    (cifsMountPair {
      share = "FTPRoot";
      where = "/mnt/FTPRoot";
    })
  ];
in {
  environment.systemPackages = with pkgs; [cifs-utils];

  systemd = {
    mounts = map (p: p.mount) mountPairs;
    automounts = map (p: p.automount) mountPairs;
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data 0755 0 0 -"
    "d /mnt/linuxdata 0755 0 0 -"
    "d /mnt/Downloads 0755 1000 1000 -"
    "d /mnt/FTPRoot 0755 1000 1000 -"
  ];
}
