# Function to create a home-manager configuration (NixOS or Darwin)
{
  lib,
  inputs,
  isDarwin,
  ...
}: hostArgs: username: hostname: let
  isDarwinHome = isDarwin hostArgs;
in {
  home-manager = {
    extraSpecialArgs = {inherit hostArgs inputs;};
    useGlobalPkgs = true;
    useUserPackages = true;

    backupFileExtension = "hm";
    users.${username}.imports = [
      ../home/${hostname}
      (
        if !isDarwinHome
        then inputs.plasma-manager.homeManagerModules.plasma-manager
        else {}
      )
    ];
  };
}
