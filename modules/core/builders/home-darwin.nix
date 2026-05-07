{
  lib,
  inputs,
  self,
  hostsDir,
  name,
  users,
  pkgs,
  pkgsUnstable,
}: {
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    extraSpecialArgs = {
      inherit self inputs pkgsUnstable;
      pkgsStable = pkgs;
      hostname = name;
    };

    users = lib.genAttrs users (user: {
      imports = let
        userHomeFile = hostsDir + "/${name}/home-${user}.nix";
      in
        lib.optional (builtins.pathExists userHomeFile) userHomeFile;

      home.username = lib.mkDefault user;
    });
  };
}
