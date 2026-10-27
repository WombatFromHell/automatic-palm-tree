{inputs, ...}: {
  imports = [inputs.xilo.homeModules.default];
  programs.xilo.enable = true;
}
