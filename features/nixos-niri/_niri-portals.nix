{
  pkgs,
  lib,
  config,
  ...
}: let
  desktop = import ./_desktop.nix {inherit config;};

  # Portal routing for the niri session follows whichever DE is installed;
  # hardcoding KDE impls here made a GNOME host route everything to kwallet.
  impls =
    {
      kde = [
        "kde"
        "gtk"
      ];
      gnome = [
        "gnome"
        "gtk"
      ];
      none = ["gtk"];
    }.${
      desktop
    };
in {
  config = lib.mkIf config.features.niri.enable {
    xdg.portal = {
      enable = true;
      extraPortals = with pkgs;
        [
          xdg-desktop-portal-gtk
        ]
        ++ lib.optionals (desktop == "kde") [kdePackages.xdg-desktop-portal-kde];
      config.niri =
        {
          default = impls;
          "org.freedesktop.impl.portal.FileChooser" =
            lib.optionals (desktop == "kde") ["kde"] ++ ["gtk"];
        }
        // lib.optionalAttrs (desktop == "kde") {
          "org.freedesktop.impl.portal.Secret" = ["kwallet"];
          "org.freedesktop.impl.portal.Print" = ["kde"];
        };
    };
  };
}
