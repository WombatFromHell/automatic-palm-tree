{
  inputs,
  pkgsUnstable,
  ...
}: {
  imports = [
    (inputs.nixpkgs-unstable + "/nixos/modules/services/scheduling/scx-loader.nix")
  ];

  services.scx-loader = {
    enable = true;
    package = pkgsUnstable.scx-loader;
  };
}
