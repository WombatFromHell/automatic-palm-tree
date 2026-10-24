{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    btrfs-progs
    snapper
  ];
  services = {
    snapper = {
      snapshotInterval = "hourly";
      cleanupInterval = "1d";
      configs.root = {
        SUBVOLUME = "/";
        ALLOW_USERS = ["@wheel"];
        TIMELINE_CREATE = true;
        TIMELINE_CLEANUP = true;
        TIMELINE_LIMIT_HOURLY = "3";
        TIMELINT_LIMIT_DAILY = "3";
        TIMELINE_LIMIT_WEEKLY = "3";
        TIMELINE_LIMIT_MONTHLY = "3";
        TIMELINT_LIMIT_YEARLY = "0";
      };
    };
    btrfs = {
      autoScrub = {
        enable = true;
        fileSystems = ["/"];
      };
    };
  };
}
