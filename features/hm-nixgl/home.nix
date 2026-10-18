{
  config,
  pkgs,
  ...
}: {
  targets.genericLinux.nixGL = {
    packages = pkgs.flakePackages.nixgl;
    defaultWrapper = "mesa";
  };
}
