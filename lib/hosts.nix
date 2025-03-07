rec {
  methyl = {
    enable = true;
    hm-only = false;
    system = "x86_64-linux";
    username = "josh";
    myuid = 1000;
    hostname = "methyl";
  };
  methyl-bazzite = {
    enable = true;
    hm-only = true;
    hostname = "methyl-bazzite";
    inherit (methyl) system username myuid;
  };
  propyl = {
    enable = true;
    hm-only = false;
    system = "x86_64-darwin";
    inherit (methyl) username;
    myuid = 501;
    hostname = "propyl";
  };
}
