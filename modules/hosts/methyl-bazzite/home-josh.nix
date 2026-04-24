{pkgs, ...}: {
  imports = [
    ../../home-manager
    ../../home-manager/dev.nix
    ../../home-manager/gpg.nix
  ];
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
