{
  lib,
  pkgs,
}:
pkgs.stdenv.mkDerivation {
  pname = "lsfg-vk";
  version = "v2.0.0-dev";

  src = pkgs.fetchFromGitHub {
    owner = "PancakeTAS";
    repo = "lsfg-vk";
    rev = "218820e8dc2d69c21a7a0775b5c47f2c447ed31a";
    hash = "sha256-Qb3vufCzNpM1r+vgo8M9nnA7CENgGTithWG0oXqLKbI=";
    fetchSubmodules = true;
  };

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    llvm
    clang
  ];

  buildInputs = with pkgs; [
    vulkan-headers
    vulkan-loader
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=On"
    "-DCMAKE_CXX_CLANG_TIDY="
  ];

  meta = with lib; {
    description = "Lossless Scaling Frame Generation on Linux — a Vulkan implicit layer";
    homepage = "https://github.com/PancakeTAS/lsfg-vk";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
    mainProgram = "lsfg-vk-cli";
  };
}
