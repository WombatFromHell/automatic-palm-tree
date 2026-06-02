_: {
  networking = {
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };
    wireless.iwd = {
      enable = true;
      settings = {
        General.Country = "US";
        IPv6.Enabled = true;
        Settings.AutoConnect = true;
      };
    };
  };

  systemd.services.NetworkManager.wantedBy = ["multi-user.target"];
}
