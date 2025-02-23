# Function to create a home-manager configuration (NixOS or Darwin)
{
  lib,
  inputs,
  isDarwin,
  ...
}: hostArgs: username: hostname: let
  isDarwinHome = isDarwin hostArgs;
in {
  extraSpecialArgs = {inherit hostArgs inputs;};
  useGlobalPkgs = true;
  useUserPackages = true;

  backupFileExtension = "hm";
  users.${username}.imports =
    [../home/${hostname}]
    # modules that only apply on NixOS
    ++ lib.optional (!isDarwinHome) [
      inputs.plasma-manager.homeManagerModules.plasma-manager
    ];
}
