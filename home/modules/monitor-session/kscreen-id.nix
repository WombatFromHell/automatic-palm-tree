{pkgs}: let
  kscreenScriptContent = builtins.readFile ./kscreen-id.py;
  rawScript = pkgs.writeScriptBin "kscreen-id" kscreenScriptContent;
in
  # expose 'kscreen-id' script as a basic derivation
  pkgs.runCommand "kscreen-id-wrapper" {
    buildInputs = [pkgs.makeWrapper];
  } ''
    mkdir -p $out/bin
    makeWrapper ${rawScript}/bin/kscreen-id $out/bin/kscreen-id \
      --prefix PATH : "${pkgs.lib.makeBinPath [pkgs.kdePackages.libkscreen]}"
  ''
