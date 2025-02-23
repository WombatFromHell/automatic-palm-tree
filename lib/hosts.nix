rec {
  methyl = {
    enable = true;
    system = "x86_64-linux";
    username = "josh";
    myuid = 1000;
    hostname = "methyl";
  };
  propyl = {
    enable = true;
    system = "x86_64-darwin";
    inherit (methyl) username;
    myuid = 501;
    hostname = "propyl";
  };
}
