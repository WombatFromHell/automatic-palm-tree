{pkgs, ...}: {
  programs.nh = {
    enable = true;
    package = pkgs.unstable.nh;
  };
}
