{
  lib,
  flakeHostOptions,
  flakeHost,
  ...
}:
# ── host facts, typed ──
# Declares `flakeHost`, the only host data modules may read. The builders set it
# once per host (lib/builders.nix mkHostFactsModule), so consumers read config.flakeHost
# instead of an untyped injected record. It is typed with flakeHostOptions: the facts a
# host file declares plus what discovery derives (the host name and the usernames), so an
# undeclared host attribute is a type error instead of a silent default.
let
  admins = lib.filter (n: flakeHost.users.${n}.isAdmin) (lib.attrNames flakeHost.users);
in {
  options.flakeHost = lib.mkOption {
    type = lib.types.submodule {
      options = flakeHostOptions;
    };
    description = "Host facts: the facts a host file declares plus the username lists the builders derive.";
  };

  config = {
    inherit flakeHost;

    # isAdmin only means anything on a NixOS host. This module is imported on both
    # sides, and `isNixOS` is true for home modules integrated into a NixOS host,
    # so the check reads typed facts and stays silent there.
    warnings = lib.optionals (!flakeHost.isNixOS && admins != []) [
      "${flakeHost.name}: 'isNixOS = false', but users.${lib.concatStringsSep ", " admins}.isAdmin = true! This is a no-op on standalone home-manager hosts."
    ];
  };
}
