{pkgsUnstable, ...}: {
  home.stateVersion = "24.11";

  manual = {
    html.enable = false;
    json.enable = false;
    manpages.enable = false;
  };

  programs = {
    home-manager.enable = true;
    nh = {
      enable = true;
      package = pkgsUnstable.nh;
    };
  };
}
