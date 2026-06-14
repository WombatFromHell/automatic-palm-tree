{
  inputs,
  lib,
  hostConfig,
  ...
}: {
  # expose 'pkgs.quickshell' via overlay (only post-bootstrap)
  featureOverlays =
    lib.optionals
    (!hostConfig.bootstrap && inputs ? quickshell)
    [inputs.quickshell.overlays.default];
}
