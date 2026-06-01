_: {
  networking = {
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };
    wireless.iwd = {
      enable = true;
      settings = {
        Country = "US";
        IPv6.Enabled = true;
        Settings.AutoConnect = true;
      };
    };
  };
}
