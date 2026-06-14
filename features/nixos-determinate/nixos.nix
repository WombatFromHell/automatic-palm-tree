{
  inputs,
  lib,
  ...
}: {
  imports = lib.optional (inputs ? determinate) inputs.determinate.nixosModules.default;
}
