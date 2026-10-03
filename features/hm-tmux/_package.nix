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
}:
stdenv.mkDerivation {
  pname = "tmux";
  version = "3.8"; # date of the pinned rev

  outputs = ["out" "man"];

  src = fetchFromGitHub {
    owner = "tmux";
    repo = "tmux";
    rev = "596d04a1937d0f62aaa5f945a59311fa0c9cb924";
    hash = "sha256-oWcj+7yWNVIWMxxWX4RGuuz5MOvMdS02Hz0TpR7Cjr0=";
  };

  nativeBuildInputs = [autoreconfHook bison pkg-config];

  buildInputs =
    [libevent ncurses utf8proc]
    ++ lib.optionals stdenv.hostPlatform.isLinux [systemdLibs libutempter];

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
