{pkgs, ...}: {
  home.packages = with pkgs.unstable; [
    trash-cli
  ];

  features = {
    oomd.notify = true;
  };
}
