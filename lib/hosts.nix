rec {
  methyl = {
    enable = true;
    hm-only = false;
    system = "x86_64-linux";
    username = "josh";
    myuid = 1000;
    hostname = "methyl";
  };
  propyl = {
    enable = true;
    hm-only = false;
    system = "x86_64-darwin";
    inherit (methyl) username;
    myuid = 501;
    hostname = "propyl";
  };
  methyl-bazzite = {
    enable = true;
    hm-only = true;
    hostname = "methyl-bazzite";
    inherit (methyl) system username myuid;
  };
  # test machines
  oxyl-cachyos = {
    hostname = "oxyl-cachyos";
    inherit (methyl-bazzite)
      system
      enable
      hm-only
      myuid
      username
      ;
  };
  oxyl-bazzite = {
    hostname = "oxyl-bazzite";
    inherit (methyl-bazzite)
      system
      enable
      hm-only
      myuid
      username
      ;
  };
}
