{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  vulkan-headers,
  vulkan-loader,
  vulkan-utility-libraries,
}:
stdenv.mkDerivation {
  pname = "low_latency_layer";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "Korthos-Software";
    repo = "low_latency_layer";
    rev = "4e7fe12b797d89be07919acf3d2df5cda3f4d89f";
    hash = "sha256-mnGAH0m19wOkWEowpcPRHXQSc6HGYW+CFYxjPF2onk4=";
  };

  nativeBuildInputs = [cmake];
  buildInputs = [vulkan-headers vulkan-loader vulkan-utility-libraries];

  meta = with lib; {
    description = "A C++23 implicit Vulkan layer that reduces click-to-photon latency";
    homepage = "https://github.com/Korthos-Software/low_latency_layer";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
