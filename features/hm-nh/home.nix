{pkgsUnstable, ...}: {
  programs.nh = {
    enable = true;
    package = pkgsUnstable.nh;
  };
}
