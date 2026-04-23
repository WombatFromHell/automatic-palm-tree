{
  lib,
  hostsDir,
}: let
  isHomeFile = n: lib.hasPrefix "home-" n && lib.hasSuffix ".nix" n;
  extractUser = n: lib.removePrefix "home-" (lib.removeSuffix ".nix" n);

  getPlatform = file: let
    val = import file;
  in
    val.platform or val.system or null;

  discoverHosts =
    lib.mapAttrs
    (name: _: let
      hostPath = hostsDir + "/${name}";
      entries = builtins.readDir hostPath;
      hasSystem = entries ? "system.nix";

      users =
        map extractUser
        (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && isHomeFile n) entries));

      sysPlat =
        if hasSystem
        then getPlatform (hostPath + "/system.nix")
        else null;

      usrPlat =
        if users != []
        then getPlatform (hostPath + "/home-${lib.head users}.nix")
        else null;

      platform =
        if sysPlat != null
        then sysPlat
        else if usrPlat != null
        then usrPlat
        else "x86_64-linux";
    in {
      inherit hasSystem users platform;
    })
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir hostsDir));
in {
  inherit discoverHosts;
}
