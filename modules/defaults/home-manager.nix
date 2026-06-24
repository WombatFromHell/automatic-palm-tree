{
  lib,
  user,
  ...
}: {
  home.stateVersion = "24.11";
  manual.html.enable = false;
  manual.json.enable = false;
  manual.manpages.enable = false;
  programs.home-manager.enable = true;
  home.username = lib.mkDefault user;
  home.homeDirectory = lib.mkDefault "/home/${user}";
}
