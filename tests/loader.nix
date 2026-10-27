# Loader suite: feature discovery, host discovery, profile merging, and the
# guards that must fire. Pure Nix — no nixpkgs evaluation, so it runs in ~0.2s.
#
# Nix 2.34 lists are whitespace-separated (no commas), and function application
# binds tighter than == / &&, so each check's condition must be its own paren.
let
  s = import ./support.nix;
  inherit (s) lib features hosts hostsAt hostLib ck suite;

  d = hosts.discoveredHosts;
  fixtureHosts = hostsAt ./fixtures;
  # Must-throw guards live in tests/red/ and are gated by tests/run.sh:
  # unknown feature, duplicate host name, module-shaped host file, host file
  # setting a derived attribute.

  featureNames = builtins.attrNames features.discoveredFeatures;
  onDisk = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../features);
  hmNames = lib.filter (n: lib.hasPrefix "hm-" n) featureNames;

  # A feature is usable if it contributes at least one module on some platform.
  resolves = f: lib.any (p: (features.resolveFeaturePaths [f] p) != []) ["nixos" "home" "overlays"];

  homeBearing =
    lib.filterAttrs (_: f: builtins.hasAttr "home" f) features.discoveredFeatures;

  # host-lib treats anything with `_type` as a leaf, so this stands in for a
  # derivation without evaluating one.
  leafStub = {_type = "derivation";};

  mergeHomeCase = hostLib.mergeHome [
    {
      isNixOS = true;
      nixosModules = [./x];
      features = ["hm-base" "hm-tmux"];
      users.josh.isAdmin = true;
    }
  ];

  checks = [
    # --- feature discovery --------------------------------------------------
    (ck "every features/ directory is discovered" (featureNames == builtins.attrNames onDisk))
    (ck "hm-* features contribute a home module"
      (lib.all (n: features.discoveredFeatures.${n} ? home) hmNames))
    (ck "nixos-* features contribute a nixos module"
      (lib.all (n: features.discoveredFeatures.${n} ? nixos)
        (lib.filter (n: lib.hasPrefix "nixos-" n) featureNames)))
    (ck "overlay-bearing features are discovered"
      ((lib.filter (n: features.discoveredFeatures.${n} ? overlays) featureNames) == ["nixos-cachyos" "nixos-niri"]))
    # Every home-bearing feature must resolve to exactly its own home.nix, so a
    # feature list in a host or profile is a promise that the module exists.
    (ck "resolveFeaturePaths maps each home-bearing feature to its home.nix"
      (lib.all
        (f: (map toString (features.resolveFeaturePaths [f] "home")) == [(toString ../features/${f}/home.nix)])
        (lib.attrNames homeBearing)))

    # --- host discovery -----------------------------------------------------
    (ck "host names match hosts/" (builtins.attrNames d == ["methyl" "methyl-bazzite" "methyl-nixos" "propyl"]))
    (ck "every feature a host lists resolves to a module" (lib.all (host: lib.all resolves host.features) (builtins.attrValues d)))
    (ck "the standalone host lists no nixos-* features" (lib.all (f: !lib.hasPrefix "nixos-" f) d.methyl-bazzite.features))
    (ck "NixOS hosts carry nixos modules; the standalone host carries none"
      ((lib.all (h: builtins.length h.nixosModules > 0) [d.methyl d.methyl-nixos d.propyl]) && (d.methyl-bazzite.nixosModules == [])))
    (ck "josh is the only home-manager user on every host" (lib.all (h: h.hmUsernames == ["josh"]) (builtins.attrValues d)))
    # The standalone host has no `users` at all, so it derives no admins; the NixOS
    # hosts get josh from methyl-base/core.nix.
    (ck "adminUsernames derives from isAdmin on enabled users"
      ((lib.all (h: h.adminUsernames == ["josh"]) [d.methyl d.methyl-nixos d.propyl])
        && (d.methyl-bazzite.adminUsernames == [])))

    # --- host file validation (fixtures) ------------------------------------
    (ck "a flat host record derives users from facts"
      ((fixtureHosts.discoveredHosts.flat.osUsernames == ["alice" "bob"])
        && (fixtureHosts.discoveredHosts.flat.hmUsernames == ["alice"])
        && (fixtureHosts.discoveredHosts.flat.adminUsernames == ["alice"])))
    (ck "a directory host auto-discovers nixos.nix and home-*.nix"
      ((fixtureHosts.discoveredHosts.dirhost.nixosModules == [./fixtures/hosts/dirhost/nixos.nix])
        && (fixtureHosts.discoveredHosts.dirhost.homeModules ? guest)
        && (fixtureHosts.discoveredHosts.dirhost.osUsernames == ["guest" "josh"])))

    # --- hostLib merge semantics --------------------------------------------
    # mergeModules = lib.foldl' mergeAttrs {}, so it takes ONE list of modules.
    (ck "mergeModules: later scalar wins" ((hostLib.mergeModules [{a = 1;} {a = 2;}]).a == 2))
    (ck "mergeModules: lists union and deduplicate" ((hostLib.mergeModules [{l = [1 2];} {l = [2 3];}]).l == [1 2 3]))
    (ck "mergeModules: nested attrsets deep-merge" ((hostLib.mergeModules [
        {
          n = {
            x = 1;
            y = 2;
          };
        }
        {n = {y = 3;};}
      ]).n
      == {
        x = 1;
        y = 3;
      }))
    (ck "mergeModules: a derivation-shaped leaf beats attrs" ((hostLib.mergeModules [{leaf = {a = 1;};} {leaf = leafStub;}]).leaf._type == "derivation"))
    (ck "profiles merge through hostLib" ((hostLib.mergeModules (hostLib.profiles ./fixtures/profiles ["a" "b"])).features == ["x" "y"]))
    # A feature reached through two paths (profile + host) must import ONE module,
    # not two — duplicate imports throw "already declared" at evaluation.
    (ck "mergeModules dedupes a feature reached through two paths"
      ((hostLib.mergeModules [{features = ["a" "b"];} {features = ["a"];}]).features == ["a" "b"]))

    # --- mergeHome: the footgun that turns a profile into a standalone host --
    # A home-only feature list survives untouched; a `nixos-` one is a red guard.
    (ck "mergeHome forces a standalone host record"
      ((mergeHomeCase.isNixOS == false)
        && (mergeHomeCase.nixosModules == [])
        && (mergeHomeCase.features == ["hm-base" "hm-tmux"])
        && (mergeHomeCase.users.josh.isAdmin == false)))
  ];
in
  suite "loader" checks
