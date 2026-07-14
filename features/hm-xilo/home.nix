{inputs, ...}: {
  imports = [inputs.xilo.homeModules.default];
  config = {
    programs.xilo.enable = true;
  };
}
