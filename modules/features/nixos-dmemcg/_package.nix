{
  lib,
  rustPlatform,
  fetchgit,
  pkg-config,
  dbus,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "dmemcg-booster";
  version = "0.1.2";

  src = fetchgit {
    url = "https://gitlab.steamos.cloud/holo/dmemcg-booster";
    rev = "903e18c761c41ecca2a6dced9335a2c3f0703b11";
    hash = "sha256-Lr39MJbzHB/ZQ43lGCWiU3SIrZayvOdkJwPU13HmrQY=";
  };

  nativeBuildInputs = [pkg-config];
  buildInputs = [dbus];

  cargoLock = {
    lockFile = finalAttrs.src + "/Cargo.lock";
  };

  meta = with lib; {
    description = "dmemcg protection for foreground VRAM when gaming";
    homepage = "https://gitlab.steamos.cloud/holo/dmemcg-booster";
    license = licenses.mit;
    platforms = platforms.linux;
  };
})
