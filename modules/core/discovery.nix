{
  lib,
  hostsDir,
}: let
  readMeta = name: let
    path = hostsDir + "/${name}/default.nix";
  in
    if builtins.pathExists path
    then import path
    else {};

  isHomeFile = n: lib.hasPrefix "home-" n && lib.hasSuffix ".nix" n;
  extractUser = n: lib.removePrefix "home-" (lib.removeSuffix ".nix" n);

  discoverHosts =
    lib.mapAttrs (name: _: let
      meta = readMeta name;
      entries = builtins.readDir (hostsDir + "/${name}");
      modules = lib.filterAttrs (n: _: n != "default.nix") entries;
    in {
      platform = meta.platform or "x86_64-linux";
      hasSystem = modules ? "system.nix";
      users =
        map extractUser
        (lib.attrNames (lib.filterAttrs
          (n: t: t == "regular" && isHomeFile n)
          modules));
    })
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir hostsDir));
in {inherit discoverHosts;}
