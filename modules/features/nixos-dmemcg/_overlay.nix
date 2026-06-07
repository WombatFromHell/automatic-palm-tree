final: _prev: let
  # Fetch the specific commit from the SteamOS GitLab repository
  src = final.fetchgit {
    url = "https://gitlab.steamos.cloud/holo/dmemcg-booster";
    rev = "903e18c761c41ecca2a6dced9335a2c3f0703b11";
    hash = "sha256-Lr39MJbzHB/ZQ43lGCWiU3SIrZayvOdkJwPU13HmrQY=";
  };
in {
  dmemcg-booster = final.rustPlatform.buildRustPackage {
    pname = "dmemcg-booster";
    version = "0.1.2";

    inherit src;

    nativeBuildInputs = [final.pkg-config];
    buildInputs = [final.dbus];

    cargoLock = {
      lockFile = src + "/Cargo.lock";
    };
  };
}
