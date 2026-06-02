{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "niri-bin";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin
    cp gamemode.pyz $out/bin/gamemode
    chmod +x $out/bin/gamemode
    cp niri_watcher.py $out/bin/niri_watcher.py
    chmod +x $out/bin/niri_watcher.py
  '';

  meta = {
    description = "Niri compositor helper scripts";
    license = lib.licenses.mit;
    platforms = ["x86_64-linux" "aarch64-linux"];
  };
}
