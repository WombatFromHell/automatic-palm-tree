{pkgs, ...}: {
  hardware = {
    enableRedistributableFirmware = true;
    wirelessRegulatoryDatabase = true;
  };
  boot = {
    extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom="US"
    '';
    kernel.sysctl = {
      "net.ipv6.conf.all.use_tempaddr" = 2;
      "net.ipv6.conf.default.use_tempaddr" = 2;
      "net.core.default_qdisc" = "fq_codel";
      "net.ipv4.tcp_congestion_control" = "bbr";
      "net.ipv6.tcp_congestion_control" = "bbr";
    };
  };
  networking = {
    networkmanager.enable = true;
    enableIPv6 = true;
    nftables.enable = true;
    firewall.enable = true;
  };
  environment.systemPackages = with pkgs; [iw wirelesstools];
}
