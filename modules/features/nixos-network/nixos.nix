_: {
  networking = {
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };
    wireless.iwd = {
      settings = {
        General.Country = "US";
        Network.EnableIPv6 = true;
        Settings.AutoConnect = true;
      };
    };
  };
}
