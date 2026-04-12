{pkgs, ...}: {
  imports = [ ../../home-manager ];
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
