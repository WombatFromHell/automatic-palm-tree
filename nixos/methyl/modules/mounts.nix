{
  config,
  lib,
  hostArgs,
  ...
}: let
  moduleName = "local-mounts";
  myuid = toString hostArgs.myuid;
  mygid = toString config.users.groups.users.gid;
in {
  options."${moduleName}".enable = lib.mkEnableOption "User configured local filesystem mounts";

  config = lib.mkIf config."${moduleName}".enable {
    # enable samba shares
    services.gvfs.enable = true;
    fileSystems = let
      automount_opts = "credentials=/etc/nixos/.smb-secrets,nofail,uid=${myuid},gid=${mygid},dir_mode=0770,file_mode=0660,x-systemd.automount,noauto,x-systemd.idle-timeout=300,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
      ext4_opts = "noatime,nofail,x-systemd.mount-timeout=3,x-gvfs-show";
    in {
      "/mnt/linuxgames" = {
        device = "/dev/disk/by-uuid/986caee7-003e-4978-ba9d-f35ffd8f007c";
        fsType = "ext4";
        options = ["${ext4_opts}"];
      };
      "/mnt/linuxdata" = {
        device = "/dev/disk/by-uuid/45710fdb-8f12-432e-998b-9dce7dfaeadd";
        fsType = "ext4";
        options = ["${ext4_opts}"];
      };

      # cifs mounts
      "/mnt/home" = {
        device = "//192.168.1.153/home";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
      "/mnt/FTPRoot" = {
        device = "//192.168.1.153/FTPRoot";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
      "/mnt/Downloads" = {
        device = "//192.168.1.153/Downloads";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
    };
  };
}
