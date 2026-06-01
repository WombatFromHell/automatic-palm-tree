{pkgsUnstable, ...}: {
  programs = {
    dms-shell = {
      enable = true;
      package = pkgsUnstable.dms-shell;
      quickshell.package = pkgsUnstable.quickshell;
    };
    niri = {
      enable = true;
      package = pkgsUnstable.niri;
    };
  };
}
