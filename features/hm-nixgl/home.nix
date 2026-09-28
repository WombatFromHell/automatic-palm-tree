{
  config,
  inputs,
  ...
}: {
  targets.genericLinux.nixGL = {
    inherit (inputs.nixgl) packages;
    defaultWrapper = "mesa";
  };
  lib.nixGL.wrapMesa = pkg:
    if config.lib ? nixGL
    then config.lib.nixGL.wrappers.mesa pkg
    else pkg;
}
