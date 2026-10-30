# The nixGL wrap around a derived package: active on a non-NixOS host, disabled on a NixOS
# one. Eval-only — derivations are compared by outPath, never built (pathExists on a
# derivation would force a build, so store-layout facts live in tests/appdir.nix instead).
let
  s = import ./support.nix;
  inherit (s) lib pkgs ck suite;

  # Three fixture Home Manager configs over typed host facts (support.nix's hmFixture): a NixOS
  # side where the wrap must be a no-op, a standalone side with the default wrapper, and a
  # standalone side choosing an Nvidia one. All set passwordStore, the one path where Home
  # Manager overrides the package its program option installs.
  fixture = {brave-browser.passwordStore = "basic";};
  nixosHost = s.hmFixture true fixture;
  standalone = s.hmFixture false fixture;
  nvidiaHost = s.hmFixture false (fixture // {nixgl.wrapper = "nvidiaPrime";});

  # The derivation before the wrap, called the way production does: pinMeta comes from
  # support.nix's overlay, and hm-brave reads pkgs.unstable.
  raw = {
    brave = pkgs.unstable.callPackage ../features/hm-brave/_package.nix {};
    zed = (pkgs.callPackage ../features/hm-zed/_package.nix {}).noFHS;
    ghostty = pkgs.callPackage ../features/hm-ghostty/_package.nix {};
  };

  # hm-brave's installPhase wraps its bin entries only when flags are present, so this is the
  # overridden-but-unwrapped derivation.
  braveWithArgs = pkgs.unstable.callPackage ../features/hm-brave/_package.nix {
    commandLineArgs = "--password-store=basic";
  };

  # The package each feature hands to its program option, and the package that option actually
  # installs (programs.chromium overrides its package when commandLineArgs are set).
  pkgOf = cfg: {
    brave = cfg.programs.chromium.package;
    zed = cfg.programs.zed-editor.package;
    ghostty = cfg.programs.ghostty.package;
  };
  finalBrave = cfg: cfg.programs.chromium.finalPackage;

  # Ghostty's launcher resolves its AppDir from /proc/self/exe, so the wrap must still run the
  # launcher from the AppDir itself. The .drv text is the eval-only form of that fact: Home
  # Manager's wrapper links the tree (`cp -rs`) and makeWrapper execs the original launcher
  # through nixGL's combined wrapper. A pattern may not contain a store path (FiFOD guard), so
  # the names are spelled out here rather than read off the derivation; the .drv is one line, so
  # plain .* is enough (builtins.match has no (?s) flag).
  wrappedGhosttyDrvText = builtins.readFile (standalone.lib.nixGL.wrapGpu raw.ghostty).drvPath;
  appDirNamed = "${raw.ghostty.pname}-${raw.ghostty.version}.drv";
  launcherInAppDir =
    builtins.match ".*${appDirNamed}.*" wrappedGhosttyDrvText
    != null
    && builtins.match ".*cp -rs.*" wrappedGhosttyDrvText != null
    && builtins.match ".*makeWrapper.*nixGLCombinedWrapper.*" wrappedGhosttyDrvText != null;

  occurrences = cfg: name: lib.length (lib.filter (p: (p.pname or p.name) == name) cfg.home.packages);

  # pnames as Home Manager sees them: brave's derivation is brave-bin, zed's zed-editor-bin.
  featureNames = ["brave-bin" "zed-editor-bin" "ghostty-bin"];
  names = lib.attrNames raw;

  # Identity or a distinct derivation, per feature, on one side.
  side = cfg: wrapped: lib.all (n: ((pkgOf cfg).${n}.outPath != raw.${n}.outPath) == wrapped) names;
in
  suite "wrap" [
    # Both disable paths are asserted, so the identity check cannot pass vacuously: hm-nixgl
    # leaves packages null on a NixOS host, and Home Manager's wrapper is a no-op on null.
    (ck "hm-nixgl leaves nixGL packages null on a NixOS host"
      (isNull nixosHost.targets.genericLinux.nixGL.packages))

    (ck "hm-nixgl sets nixGL packages on a non-NixOS host"
      (!isNull standalone.targets.genericLinux.nixGL.packages))

    # modules/defaults/home-manager.nix declares lib.nixGL.wrapGpu unconditionally so every
    # consumer can call it; here it must be identity.
    (ck "wrapGpu is identity on a NixOS host"
      (lib.all (n: (nixosHost.lib.nixGL.wrapGpu raw.${n}).outPath == raw.${n}.outPath) names))

    (ck "every wrapped package is used unwrapped on a NixOS host" (side nixosHost false))

    # The wrapping branch must produce a different derivation and keep the package's identity,
    # or the program options would read resources from a path that does not exist.
    (ck "wrapGpu returns a distinct derivation on a non-NixOS host"
      (lib.all (n: (standalone.lib.nixGL.wrapGpu raw.${n}).outPath != raw.${n}.outPath) names))

    (ck "every wrapped package is wrapped on a non-NixOS host" (side standalone true))

    # The house helper must be Home Manager's wrapper, not a hardcoded one: it delegates to
    # lib.nixGL.wrap, which is the function Home Manager picks from defaultWrapper below.
    (ck "wrapGpu delegates to Home Manager's lib.nixGL.wrap"
      ((standalone.lib.nixGL.wrapGpu raw.ghostty).outPath
        == (standalone.lib.nixGL.wrap raw.ghostty).outPath))

    # The wrapper Home Manager uses must come from the host's option, not a hardcoded mesa, or a
    # host with an Nvidia GPU would run Intel's driver set. Only the option level is assertable on
    # this box: forcing an Nvidia wrapper fails, because nixGL's Nvidia wrapper reads the host's
    # driver version and gets null here (shortcut: the Nvidia branch is unverified until a host
    # with an Nvidia GPU runs the gate). lib.nixGL.wrap is what wrapGpu delegates to, and Home
    # Manager's own module picks wrappers.${defaultWrapper}.
    (ck "the wrapper follows the host's features.nixgl.wrapper"
      (nixosHost.targets.genericLinux.nixGL.defaultWrapper
        == "mesa"
        && standalone.targets.genericLinux.nixGL.defaultWrapper == "mesa"
        && nvidiaHost.targets.genericLinux.nixGL.defaultWrapper == "nvidiaPrime"
        && builtins.elem "nvidiaPrime" (lib.attrNames nvidiaHost.lib.nixGL.wrappers)))

    # The commandLineArgs override is an option value, so the branch is asserted as one: the
    # flag reaches programs.chromium and the overridden package keeps its identity. Wrapped vs
    # plain is carried by the checks above (the package option is a distinct derivation here,
    # identity on the NixOS side), because a wrapper keeps pname and version - names alone
    # cannot tell them apart, and reading finalPackage.outPath forces Home Manager's whole
    # chromium override chain (~300MB on top of Brave's dependency closure).
    (ck "programs.chromium applies the commandLineArgs override to a wrapped package"
      (lib.head standalone.programs.chromium.commandLineArgs
        == "--password-store=basic"
        && (finalBrave standalone).pname == raw.brave.pname
        && (finalBrave standalone).version == raw.brave.version))

    # On a NixOS host the override still fires, so wrapGpu must be identity on the *overridden*
    # derivation too: identity here means "no nixGL wrapper", not "no override".
    (ck "the override stays unwrapped on a NixOS host"
      (lib.head nixosHost.programs.chromium.commandLineArgs
        == "--password-store=basic"
        && (nixosHost.lib.nixGL.wrapGpu braveWithArgs).outPath == braveWithArgs.outPath))

    # hm-brave's installPhase only wraps its bin entries when flags are present; without this
    # the override would silently drop --password-store.
    (ck "brave's derivation wraps its bin entries when commandLineArgs are set"
      (builtins.match ".*makeWrapper.*--password-store=basic.*" (builtins.readFile braveWithArgs.drvPath)
        != null
        && builtins.match ".*ln -s .*/opt/brave.com/brave/brave.*" (builtins.readFile raw.brave.drvPath) != null))

    # Identity alone is not enough: a wrapper that copied bin/ghostty into an empty tree would
    # keep the pname and still resolve no resources at runtime.
    (ck "the wrapped Ghostty links the AppDir and execs its launcher through nixGL" launcherInAppDir)

    (ck "a wrapped package keeps its pname and version"
      (lib.all
        (n:
          (pkgOf standalone).${n}.pname
          == raw.${n}.pname
          && (pkgOf standalone).${n}.version == raw.${n}.version)
        names))

    # PATH contract: the program module installs its own package (programs.chromium adds
    # finalPackage, programs.zed-editor adds package), so the feature must not add a second
    # copy — the profile's bin dir needs one entry per program, on both sides.
    (ck "each wrapped package reaches home.packages exactly once"
      (lib.all
        (n: (occurrences standalone n == 1) && (occurrences nixosHost n == 1))
        featureNames))

    (ck "the features are on by default and drive their program options"
      (standalone.features.brave-browser.enable
        && standalone.features.zed-editor.enable
        && standalone.features.ghostty.enable
        && standalone.programs.chromium.enable
        && standalone.programs.zed-editor.enable
        && standalone.programs.ghostty.enable))
  ]
