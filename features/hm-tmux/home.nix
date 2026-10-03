{
  lib,
  config,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.tmux-git;
  tmux-git = pkgsUnstable.callPackage ./_package.nix {};
in {
  options.features.tmux-git.enable =
    lib.mkEnableOption "tmux terminal multiplexer (built from git)" // {default = true;};

  config = lib.mkIf cfg.enable {
    home.packages = [tmux-git];
  };
}
