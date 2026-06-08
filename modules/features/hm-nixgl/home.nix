{nixgl, ...}: {
  targets.genericLinux.nixGL = {
    inherit (nixgl) packages;
    defaultWrapper = "mesa";
  };
}
