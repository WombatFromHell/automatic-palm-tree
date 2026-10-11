{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  bison,
  pkg-config,
  libevent,
  ncurses,
  utf8proc,
  systemdLibs,
  libutempter,
}: let
  # Mutable pin metadata, updated by ./update.sh.
  # version = release tag or full commit hash (passed as `rev`).
  meta = builtins.fromJSON (builtins.readFile ./metadata.json);

  system = stdenv.hostPlatform.system;

  hash =
    meta.hashes.${system}
      or (lib.throw "tmux: unsupported system '${system}'. Available: ${toString (lib.attrNames meta.hashes)}");

  src = fetchFromGitHub {
    owner = "tmux";
    repo = "tmux";
    rev = meta.version;
    inherit hash;
  };
in
  stdenv.mkDerivation {
    pname = "tmux";
    inherit (meta) version;
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
