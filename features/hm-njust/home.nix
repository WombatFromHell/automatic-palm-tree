# 'njust': a just runner pinned to the Nix deploy recipes in ./nix.just beside
# this file (port of ~/.config/fish/helpers/nix.fish + the old /etc/Justfile).
#
# Opt-in through the host feature list (hosts/<host>/default.nix → "hm-njust"),
# like every other feature — the feature list is the gate, no extra enable flag.
#
# A wrapper, not environment.variables.JUST_JUSTFILE: that would hijack plain
# `just` in every repo (~/goap/.pi/Justfile, ~/scratchpad/Justfile, ...). Only
# `njust` is bound to our justfile.
{
  pkgs,
  lib,
  ...
}: let
  # `just` from PATH, so the wrapper is not coupled to one just version.
  njust = pkgs.writeShellApplication {
    name = "njust";
    # just defaults its working directory to its own justfile's directory; keep
    # the caller's cwd so './' and {{ flake }} resolve to the flake they are in.
    text = ''exec just -f ${./nix.just} --working-directory . "$@"'';
  };
in {
  home.packages = [
    pkgs.just
    # The nix.just clients: fast build + the evaluator it delegates to.
    pkgs.lixPackageSets.latest.nix-fast-build
    pkgs.lixPackageSets.latest.nix-eval-jobs
    njust
  ];

  # {{ info }} and {{ clean }} recipes shell out to nh; hm-njust hosts do not
  # need to list hm-nh as well.
  programs.nh = {
    enable = true;
    package = lib.mkDefault pkgs.unstable.nh;
  };
}
