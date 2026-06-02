{pkgs, ...}: {
  environment.systemPackages = with pkgs; [cifs-utils];

  systemd = {
    mounts = [
      {
        type = "btrfs";
        what = "/dev/disk/by-uuid/25dc01da-4cc4-4d5b-bca7-d11f74732d0c";
        where = "/mnt/data";
        options = "noatime,compress=zstd:3,subvol=@,nofail,x-gvfs-show,x-systemd.mount-timeout=5";

        # Ensures the mount point directory exists
        requires = ["mnt-data.automount"];
        after = ["mnt-data.automount"];
      }
      {
        type = "btrfs";
        what = "/dev/disk/by-uuid/be63764a-f6bd-4687-aa07-9c7ddea97cc4";
        where = "/mnt/linuxdata";
        options = "noatime,compress=zstd:3,subvol=@,nofail,x-gvfs-show,x-systemd.mount-timeout=5";

        requires = ["mnt-linuxdata.automount"];
        after = ["mnt-linuxdata.automount"];
      }
      #
      {
        type = "cifs";
        what = "//192.168.1.153/Downloads";
        where = "/mnt/Downloads";
        options = "rw,credentials=/etc/.smb-credentials,uid=1000,gid=1000,iocharset=utf8,file_mode=0644,dir_mode=0755,x-systemd.mount-timeout=5,x-gvfs-show";
        directoryMode = "0755";

        # CRITICAL: Wait for network to be fully online before attempting mount
        requires = ["network-online.target"];
        after = ["network-online.target"];
      }
      {
        type = "cifs";
        what = "//192.168.1.153/FTPRoot";
        where = "/mnt/FTPRoot";
        options = "rw,credentials=/etc/.smb-credentials,uid=1000,gid=1000,iocharset=utf8,file_mode=0644,dir_mode=0755,x-systemd.mount-timeout=5,x-gvfs-show";
        directoryMode = "0755";

        requires = ["network-online.target"];
        after = ["network-online.target"];
      }
    ];

    automounts = [
      {
        where = "/mnt/data";
        wantedBy = ["multi-user.target"];
      }
      {
        where = "/mnt/linuxdata";
        wantedBy = ["multi-user.target"];
      }
      #
      {
        where = "/mnt/Downloads";
        timeoutIdleSec = "180"; # Unmount after 3 minutes of inactivity
        wantedBy = ["multi-user.target"];
        requires = ["network-online.target"];
        after = ["network-online.target"];
      }
      {
        where = "/mnt/FTPRoot";
        timeoutIdleSec = "180";
        wantedBy = ["multi-user.target"];
        requires = ["network-online.target"];
        after = ["network-online.target"];
      }
    ];
  };

  # ── Ensure Mount Points Exist ──────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /mnt/data 0755 0 0 -"
    "d /mnt/linuxdata 0755 0 0 -"
    "d /mnt/Downloads 0755 1000 1000 -"
    "d /mnt/FTPRoot 0755 1000 1000 -"
  ];
}
