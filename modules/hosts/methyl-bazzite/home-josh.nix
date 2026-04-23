{pkgs, ...}: {
  imports = [
    ../../home-manager
    ../../home-manager/gpg.nix
  ];
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
