{pkgs, ...}: {
  services.printing = {
    enable = true;
    drivers = [pkgs.brlaser];
  };
  hardware.printers = {
    ensureDefaultPrinter = "HL2270DW";
    ensurePrinters = [
      {
        name = "HL2270DW";
        description = "Brother HL-2270DW";
        deviceUri = "lpd://192.168.1.10/queue";
        model = "drv:///brlaser.drv/br2270d.ppd";
        ppdOptions = {
          PageSize = "A4";
          Duplex = "None";
        };
      }
    ];
  };
}
