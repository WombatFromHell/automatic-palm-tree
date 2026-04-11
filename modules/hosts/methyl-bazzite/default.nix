{pkgs, ...}: {
  # ── Host metadata ─────────────────────────────────────────────────
  hostArgs = {
    hostname = "methyl-bazzite";
    system = "x86_64-linux";
    username = "josh";
    myuid = 1000;
    hostType = "home";
  };

  # ── Module imports ────────────────────────────────────────────────
  imports = [../../home-manager];

  services = {
    gpg-agent = {
      pinentry.package = pkgs.pinentry-qt;
    };
  };
}
