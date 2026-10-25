{
  lib,
  config,
  ...
}: {
  # Unit lives NixOS-side (features/nixos-dms/nixos.nix): Home Manager cannot
  # see which desktop/niri session is installed, and a ~/.config/systemd/user
  # unit shadows the system one — that is how the old unit started DMS in
  # Plasma/GNOME sessions too. The option stays declared here so the feature
  # namespace keeps working on standalone Linux hosts.
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service" // {default = true;};
  };
}
