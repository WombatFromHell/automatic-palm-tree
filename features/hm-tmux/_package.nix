{
  lib,
  stdenv,
  fetchFromGitHub,
  pinMeta,
  autoreconfHook,
  bison,
  pkg-config,
  libevent,
  ncurses,
  utf8proc,
  systemdLibs,
  libutempter,
}: let
  # Mutable pin metadata, updated by ./update.sh (version = tag or commit hash).
  pin = lib.importJSON ./metadata.json;

  src = fetchFromGitHub (pinMeta.gitSource pin stdenv.hostPlatform.system);
in
  stdenv.mkDerivation {
    pname = "tmux";
    inherit (pin) version;
    inherit src;

    outputs = [
      "out"
      "man"
    ];

    nativeBuildInputs = [
      autoreconfHook
      bison
      pkg-config
    ];

    buildInputs =
      [
        libevent
        ncurses
        utf8proc
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        systemdLibs
        libutempter
      ];

    configureFlags =
      [
        "--sysconfdir=/etc"
        "--localstatedir=/var"
        "--enable-sixel"
        "--enable-utf8proc"
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        "--enable-systemd"
        "--enable-utempter"
      ];

    enableParallelBuilding = true;

    meta = {
      description = "Terminal multiplexer (git build)";
      homepage = "https://tmux.github.io/";
      license = lib.licenses.bsd3;
      platforms = lib.platforms.unix;
      mainProgram = "tmux";
    };
  }
