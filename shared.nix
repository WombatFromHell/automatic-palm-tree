rec {
  methyl = {
    enable = true;
    system = "x86_64-linux";
    username = "josh";
    myuid = 1000;
    hostname = "methyl";
    osModules = [
      "hardware-configuration.nix"
      "configuration.nix"
      "modules/nvidia.nix"
      "modules/veridian.nix"
      "modules/mounts.nix"
      "modules/gigabyte-sleepfix.nix"
      "modules/lightsout.nix"
      "modules/nvidia-pm"
    ];
    services = {
      lightsout.enable = true;
      nvidia-support.enable = true;
    };
  };
  laptop = {
    enable = false;
    system = "x86_64-darwin";
    inherit (methyl) username;
    myuid = 501;
    hostname = "MacBookPro.lan";
  };
}
