{
  pkgs,
  lib,
  ...
}: {
  services = {
    gpg-agent = {
      enable = true;
      enableSshSupport = true;
      maxCacheTtl = 60480000;
      defaultCacheTtl = 60480000;
    };
  };
}
