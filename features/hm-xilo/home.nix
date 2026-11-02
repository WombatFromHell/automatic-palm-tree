{ pkgs, inputs, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
  # The real CLI, by store path: `xilo-wrapped` execs it directly rather than through PATH,
  # which would find the wrapper itself.
  cli = inputs.xilo.packages.${system}.default;

  # Credential wrapper for the commands that need a token: XILO_URL/XILO_CACHE/XILO_TOKEN come
  # from credsctl records when there is one (a variable you exported yourself wins), otherwise
  # your environment is passed through and xilo's saved profile authenticates. Plain `xilo` is
  # untouched, so upstream behaviour stays available and nothing is shadowed.
  wrapped = pkgs.writeShellApplication {
    name = "xilo-wrapped";
    # The script lives beside this file so it is testable on its own (tests/xilo.bats); the
    # marker is where the store path goes.
    text = builtins.replaceStrings ["__XILO_PROGRAM__"] ["${cli}/bin/xilo"] (builtins.readFile ./xilo.sh);
  };
in {
  imports = [inputs.xilo.homeModules.default];

  programs.xilo.enable = true;
  # Its own package (cfg.package) stays the upstream CLI; this adds the cred-taking alias.
  home.packages = [wrapped];
}
