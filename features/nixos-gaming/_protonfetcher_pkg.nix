{pkgs}:
pkgs.callPackage ../../modules/packages/pyz-wrapper.nix {
  pname = "protonge-fetcher";
  version = "1.3.1";
  hash = "sha256-krVT9cxyT+Wx+qFAYEFvFAoW8D/XGrk/YsA9KUzIFgc=";
  repo = "WombatFromHell/protonge-fetcher";
  binName = "protonfetcher";
}
