# Core nh (Nix Helper) support for all hosts
{
  pkgs,
  self,
  ...
}: {
  environment.variables.FLAKE = "${self.outPath}";
  environment.systemPackages = [pkgs.nh pkgs.nix-output-monitor];
}
