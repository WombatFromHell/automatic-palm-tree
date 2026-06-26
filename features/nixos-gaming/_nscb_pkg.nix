{pkgs}:
pkgs.callPackage ../../modules/packages/pyz-wrapper.nix {
  pname = "neoscopebuddy";
  version = "1.1.5";
  hash = "sha256-FxzpNrHtSMGj3/jg4ok9WX5Ylr9QtTQEypgGpaEJL2U=";
  repo = "WombatFromHell/neoscopebuddy";
  binName = "nscb";
}
