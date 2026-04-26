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
    useGlobalPkgs = false;
    useUserPackages = true;

    extraSpecialArgs = {
      inherit self inputs;
      inherit pkgsUnstable;
      pkgsStable = pkgs;
      hostname = name;
    };

    users = lib.genAttrs users (user: {
      config,
      pkgs,
      ...
    }: {
      imports =
        lib.optional
        (builtins.pathExists (hostsDir + "/${name}/home-${user}.nix"))
        (hostsDir + "/${name}/home-${user}.nix");

      home.username = lib.mkDefault user;
      home.homeDirectory = lib.mkForce "/Users/${user}";
    });
  };
}
