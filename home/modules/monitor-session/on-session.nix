{pkgs, ...}: let
  onSessionScriptContent = builtins.readFile ./on-session.py;
  onSessionScript = pkgs.writeScriptBin "on-session" onSessionScriptContent;
in {
  inherit onSessionScript;
}
