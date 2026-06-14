{
  inputs,
  lib,
  hostConfig,
  ...
}: {
  # integrate determinate-nixd only when caching is enabled
  imports =
    lib.optional
    (!hostConfig.bootstrap && inputs ? determinate)
    inputs.determinate.nixosModules.default;
}
