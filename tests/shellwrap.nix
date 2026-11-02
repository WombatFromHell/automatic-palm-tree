# Build-tier guard for the two scripts Home Manager ships: features/hm-creds/credsctl.sh and
# features/hm-xilo/xilo.sh. The bats suites exercise the raw files; what ships is
# `pkgs.writeShellApplication`, which wraps them and runs nixpkgs' shellcheck on the wrapped text.
# So this builds both wrappers and tests/run.sh gates on the build's exit status — a lint error in
# the shipped form fails here, not only in a local `shellcheck` run nobody runs.
#
# xilo's real store path is a placeholder: the marker substitution and the shellcheck are what is
# under test, and neither needs the upstream CLI, so nothing is fetched.
let
  s = import ./support.nix;
  inherit (s) pkgs;
in
pkgs.symlinkJoin {
  name = "shellwrap";
  paths = [
    (pkgs.writeShellApplication {
      name = "credsctl";
      text = builtins.readFile ../features/hm-creds/credsctl.sh;
    })
    (pkgs.writeShellApplication {
      name = "xilo-wrapped";
      text = builtins.replaceStrings ["__XILO_PROGRAM__"]
        ["${pkgs.writeShellScriptBin "xilo" ""}/bin/xilo"] (builtins.readFile ../features/hm-xilo/xilo.sh);
    })
  ];
}
