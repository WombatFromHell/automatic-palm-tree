{inputs, ...}: {
  __overlays = [inputs.nixgl.overlay];

  targets.genericLinux.nixGL = {
    inherit (inputs.nixgl) packages;
    defaultWrapper = "mesa";
  };
}
