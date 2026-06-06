{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.korthos;

  # We fetch the source from GitHub and build it using standard CMake inputs.
  lowLatencyLayer = pkgs.stdenv.mkDerivation {
    pname = "Korthos' low_latency_layer";
    version = "0.2.0";

    src = pkgs.fetchFromGitHub {
      owner = "Korthos-Software";
      repo = "low_latency_layer";
      rev = "4e7fe12b797d89be07919acf3d2df5cda3f4d89f";
      hash = "sha256-mnGAH0m19wOkWEowpcPRHXQSc6HGYW+CFYxjPF2onk4=";
    };

    nativeBuildInputs = with pkgs; [
      cmake
    ];

    buildInputs = with pkgs; [
      vulkan-headers
      vulkan-loader
      vulkan-utility-libraries
    ];

    meta = with lib; {
      description = "A C++23 implicit Vulkan layer that reduces click-to-photon latency";
      homepage = "https://github.com/Korthos-Software/low_latency_layer";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };
in {
  options.features.korthos = {
    enable = lib.mkEnableOption "Korthos' Low-Latency Vulkan Layer";
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics.extraPackages = [
      lowLatencyLayer
    ];
  };
}
