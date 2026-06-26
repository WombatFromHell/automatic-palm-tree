{
  lib,
  stdenv,
  fetchurl,
  python3,
  pname,
  version,
  hash,
  repo,
  binName,
}:
stdenv.mkDerivation {
  inherit pname version;

  src = fetchurl {
    url = "https://github.com/${repo}/releases/download/v${version}/${binName}.pyz";
    inherit hash;
  };

  dontUnpack = true;
  buildInputs = [python3];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/${binName}
    chmod +x $out/bin/${binName}
    patchShebangs $out/bin/${binName}
    runHook postInstall
  '';

  meta = with lib; {
    description = pname;
    homepage = "https://github.com/${repo}";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
