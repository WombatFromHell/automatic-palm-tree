{pkgs, ...}: let
  onSessionScriptContent = builtins.readFile ./on-session.py;
  onSessionScript = pkgs.writeScriptBin "on-session" onSessionScriptContent;
  wrappedScript =
    pkgs.runCommand "wrapped-on-session" {
      nativeBuildInputs = [pkgs.makeWrapper];
    } ''
      mkdir -p $out/bin
      makeWrapper ${onSessionScript}/bin/on-session $out/bin/on-session \
        --prefix PATH : ${pkgs.python3}/bin
    '';
in {
  onSessionScript = wrappedScript;
}
