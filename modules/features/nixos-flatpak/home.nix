{pkgs, ...}: {
  systemd.user.services.flatpak-user-repo = {
    Unit = {
      Description = "Add Flathub user repository";
    };
    Install = {
      WantedBy = ["default.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.flatpak}/bin/flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo";
    };
  };
}
