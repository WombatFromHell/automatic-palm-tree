{
  lib,
  user,
  ...
}: {
  manual = {
    html.enable = false;
    json.enable = false;
    manpages.enable = false;
  };
  programs.home-manager.enable = true;
  home = {
    username = lib.mkDefault user;
    homeDirectory = lib.mkDefault "/home/${user}";
    stateVersion = "24.11";
  };
}
