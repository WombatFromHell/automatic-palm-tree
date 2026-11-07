# nix-unit attributes for the loader: feature discovery, host discovery, profile merging, and
# the authoring errors the loader must reject. Pure Nix — no nixpkgs evaluation, so the discovery
# attributes cost almost nothing.
#
# Attributes whose value must throw carry `expectedError`. They replace the tests/red/ guards,
# including the three home-side ones: the home tier's green suite forces a real host config and so
# stays outside this process, but its must-throw side is a loader/contract assertion.
let
  s = import ./support.nix;
  inherit (s) lib features featuresAt hosts hostsAt hostLib;
  inherit (import ../lib/host-options.nix {inherit lib;}) hostOptions;

  d = hosts.discoveredHosts;
  fixtureHosts = hostsAt ./fixtures;

  featureNames = builtins.attrNames features.discoveredFeatures;
  onDisk = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../features);
  hmNames = lib.filter (n: lib.hasPrefix "hm-" n) featureNames;

  # A feature is usable if it contributes at least one module on some platform.
  resolves = f: lib.any (p: (features.resolveFeaturePaths [f] p) != []) ["nixos" "home" "overlays"];

  homeBearing =
    lib.filterAttrs (_: f: builtins.hasAttr "home" f) features.discoveredFeatures;

  # `_overlays.nix` is a MODULE, not an overlay function: it contributes
  # `config.nixpkgs.overlays`, which is the only shape a feature option can gate. A file
  # returning `[ final: prev: … ]` is reachable by nothing and drops the gate silently.
  # The stub argset is exactly what the two shipped modules read -- option values, never a
  # package set -- so this costs no nixpkgs evaluation.
  overlayStub = {
    config = {
      features.niri.niriSpicy.enable = false;
      flakeCache.enable = [];
    };
    inherit lib;
    inputs = {
      nix-cachyos-kernel.overlays.pinned = [];
      niri-spicy.overlays.default = [];
    };
  };
  overlayFeatureNames = lib.filter (n: features.discoveredFeatures.${n} ? overlays) featureNames;
  isOverlayModule = f: let
    body = (import features.discoveredFeatures.${f}.overlays) overlayStub;
  in
    builtins.typeOf body
    == "set"
    && ((body.config.nixpkgs or {}) ? overlays);

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

  # Fixture roots, so each authoring error is reproduced in isolation.
  symlinkedFeatures = featuresAt ./fixtures/features;
  duplicateHosts = (hostsAt ./fixtures/duplicate).discoveredHosts;
  derivedNameHosts = (hostsAt ./fixtures/derivedname).discoveredHosts;
  rejectHosts = (hostsAt ./fixtures/reject).discoveredHosts;

  # A host that lists a kernel feature AND pins the kernel in its own nixosModules file. The
  # module system would report "defined multiple times" with two store paths and no host name;
  # this attribute wants the host and both writers named at the point the host record is still in
  # hand. Fixture module only - nothing is built or fetched.
  kernelHost =
    (s.fixtureHost true ["nixos-cachyos"] {})
    // {
      name = "kernelhost";
      nixosModules = [./fixtures/kernelhost/nixos.nix];
    };
in {
  # --- support.nix helpers ------------------------------------------------
  # A package name is on the derivation as `pname`, falling back to `name`.
  testHasPkgMatchesPname = {
    expr = s.hasPkg [{pname = "fish";}] "fish";
    expected = true;
  };
  testHasPkgMatchesName = {
    expr = s.hasPkg [{name = "yt-dlp";}] "yt-dlp";
    expected = true;
  };
  testHasPkgMissIsAMiss = {
    expr = s.hasPkg [{pname = "fish";}] "yt-dlp";
    expected = false;
  };
  # A hit must not force the elements after it — the contract that keeps a presence check from
  # evaluating every package in a config. A miss scans the whole list, so absence is asserted
  # elsewhere (tests/configs.nix).
  testHasPkgStopsAtTheFirstMatch = {
    expr = s.hasPkg [{pname = "fish";} (throw "later package forced")] "fish";
    expected = true;
  };

  # The name rule every package helper shares: the derivation says `pname`, and packages built
  # without one say `name`. It is spelled five times across the suites today.
  testPkgNamePrefersPname = {
    expr = s.pkgName { pname = "fish"; name = "fish-bin"; };
    expected = "fish";
  };
  testPkgNameFallsBackToName = {
    expr = s.pkgName { name = "yt-dlp"; };
    expected = "yt-dlp";
  };

  # --- feature discovery --------------------------------------------------
  testEveryFeaturesDirectoryIsDiscovered = {
    expr = featureNames;
    expected = builtins.attrNames onDisk;
  };
  testHmFeaturesContributeAHomeModule = {
    expr = lib.all (n: features.discoveredFeatures.${n} ? home) hmNames;
    expected = true;
  };
  testNixosFeaturesContributeANixosModule = {
    expr =
      lib.all (n: features.discoveredFeatures.${n} ? nixos)
      (lib.filter (n: lib.hasPrefix "nixos-" n) featureNames);
    expected = true;
  };
  testOverlayBearingFeaturesAreDiscovered = {
    expr = overlayFeatureNames;
    expected = ["nixos-cachyos" "nixos-niri"];
  };
  # A hand-written overlay function instead of a module passes the discovery check above and
  # contributes nothing: the loader only feeds modules to nixpkgs.
  testEveryOverlaysNixIsAModule = {
    expr = lib.all isOverlayModule overlayFeatureNames;
    expected = true;
  };
  # A feature dir can be a symlink (a checkout that points at another tree); readDir reports
  # "symlink", so a type == "directory" filter silently skipped it.
  testSymlinkedFeatureDirectoryIsDiscovered = {
    expr = lib.elem "linked" (builtins.attrNames symlinkedFeatures.discoveredFeatures);
    expected = true;
  };
  testSymlinkedFeatureModuleResolvesToItsFile = {
    expr = toString symlinkedFeatures.discoveredFeatures.linked.nixos;
    expected = toString ./fixtures/features/features/linked/nixos.nix;
  };
  # Every home-bearing feature must resolve to exactly its own home.nix, so a feature list in a
  # host or profile is a promise that the module exists.
  testResolveFeaturePathsMapsEachHomeFeatureToItsHomeNix = {
    expr =
      lib.all
      (f: (map toString (features.resolveFeaturePaths [f] "home")) == [(toString ../features/${f}/home.nix)])
      (builtins.attrNames homeBearing);
    expected = true;
  };
  # A feature name with no features/ directory must be rejected at eval time, not quietly
  # dropped from the module list.
  testUnknownFeatureThrows = {
    expr = features.resolveFeaturePaths ["definitely-not-a-feature"] "nixos";
    expectedError = {
      type = "ThrownError";
      msg = "Unknown feature";
    };
  };
  # Two kernel-pinning features in one host list is an authoring error. The module system only
  # reports it as "boot.kernelPackages is defined multiple times" with two store paths and no
  # host name, so this names the host list instead.
  testTwoKernelFeaturesThrow = {
    expr = features.resolveFeaturePaths ["nixos-cachyos" "nixos-kait2en"] "nixos";
    expectedError = {
      type = "ThrownError";
      msg = "Only one kernel feature per host";
    };
  };
  # The same collision when the host pins the kernel in its own module file instead of listing
  # the feature.
  testKernelFeatureAndHostPinCollide = {
    expr = (s.builders.buildNixosConfigurations {kernelhost = kernelHost;}).kernelhost.config.flakeHost;
    expectedError = {
      type = "ThrownError";
      msg = "pins boot.kernelPackages twice";
    };
  };

  # --- host discovery -----------------------------------------------------
  testHostNamesMatchHostsDir = {
    expr = builtins.attrNames d;
    expected = ["methyl" "methyl-bazzite" "methyl-nixos" "propyl"];
  };
  testEveryFeatureAHostListsResolves = {
    expr = lib.all (host: lib.all resolves host.features) (builtins.attrValues d);
    expected = true;
  };
  # The standalone host has no `users` at all, so it derives no admins; the NixOS hosts get
  # josh from methyl-base/core.nix.
  testStandaloneHostListsNoNixosFeatures = {
    expr = lib.all (f: !lib.hasPrefix "nixos-" f) d.methyl-bazzite.features;
    expected = true;
  };
  testNixosHostsCarryNixosModules = {
    expr = lib.all (h: builtins.length h.nixosModules > 0) [d.methyl d.methyl-nixos d.propyl];
    expected = true;
  };
  testStandaloneHostCarriesNoNixosModules = {
    expr = d.methyl-bazzite.nixosModules;
    expected = [];
  };
  testJoshIsTheOnlyHomeManagerUserEveryHost = {
    expr = lib.all (h: h.hmUsernames == ["josh"]) (builtins.attrValues d);
    expected = true;
  };
  testNixosHostsDeriveAdminFromIsAdmin = {
    expr = lib.all (h: h.adminUsernames == ["josh"]) [d.methyl d.methyl-nixos d.propyl];
    expected = true;
  };
  testStandaloneHostDerivesNoAdmins = {
    expr = d.methyl-bazzite.adminUsernames;
    expected = [];
  };

  # --- host file validation (fixtures) ------------------------------------
  testFlatHostRecordDerivesUsersFromFacts = {
    expr = fixtureHosts.discoveredHosts.flat.osUsernames;
    expected = ["alice" "bob"];
  };
  testFlatHostRecordDerivesHomeUsers = {
    expr = fixtureHosts.discoveredHosts.flat.hmUsernames;
    expected = ["alice"];
  };
  testFlatHostRecordDerivesAdmins = {
    expr = fixtureHosts.discoveredHosts.flat.adminUsernames;
    expected = ["alice"];
  };
  testDirectoryHostAutoDiscoversItsModuleFiles = {
    expr = fixtureHosts.discoveredHosts.dirhost.nixosModules;
    expected = [./fixtures/hosts/dirhost/nixos.nix];
  };
  testDirectoryHostDiscoversHomeModules = {
    expr = fixtureHosts.discoveredHosts.dirhost.homeModules ? guest;
    expected = true;
  };
  testDirectoryHostDerivesUsernames = {
    expr = fixtureHosts.discoveredHosts.dirhost.osUsernames;
    expected = ["guest" "josh"];
  };
  # Symlinked module files inside a host directory are the same silent-skip failure one level
  # down: readDir reports "symlink", not "regular".
  testSymlinkedHostNixosIsDiscovered = {
    expr = fixtureHosts.discoveredHosts.linkhost.nixosModules;
    expected = [./fixtures/hosts/linkhost/nixos.nix];
  };
  testSymlinkedHostHomeModuleIsDiscovered = {
    expr = fixtureHosts.discoveredHosts.linkhost.homeModules ? guest;
    expected = true;
  };
  # A host that declares its own module for a user must not drop the discovered
  # home-<user>.nix: `//` used to replace the whole per-user list.
  testDeclaredHomeModulesKeepTheDiscoveredModule = {
    expr = fixtureHosts.discoveredHosts.overridehost.homeModules.josh;
    expected = [
      ./fixtures/hosts/overridehost/home-josh.nix
      ./fixtures/hosts/overridehost/override.nix
    ];
  };
  testDeclaredHomeModulesKeepTheHomeUser = {
    expr = fixtureHosts.discoveredHosts.overridehost.hmUsernames;
    expected = ["josh"];
  };
  # hosts/x.nix beside hosts/x/default.nix would silently shadow one another.
  testDuplicateHostNameThrows = {
    expr = duplicateHosts.dup;
    expectedError = {
      type = "ThrownError";
      msg = "Two host definitions";
    };
  };
  # `name`, `osUsernames`, `adminUsernames` and `hmUsernames` are derived by lib/hosts.nix, so a
  # host file that sets one of them must be rejected rather than shadowed.
  testHostAuthoringADerivedNameThrows = {
    expr = derivedNameHosts.authoredName;
    expectedError = {
      type = "ThrownError";
      msg = "does not exist";
    };
  };
  # A host file is a record of facts, not a NixOS module; a stray `boot.*` line must be
  # rejected. lib/hosts.nix's guidance text is addErrorContext, which Nix prints but is not part
  # of the error message, so this asserts on the option error itself.
  testHostWrittenAsAModuleThrows = {
    expr = rejectHosts.bad;
    expectedError = {
      type = "ThrownError";
      msg = "The option `boot' does not exist";
    };
  };

  # A host fact is named for the consequence it controls (ADR-a742baa1). isQemuVM read as a
  # machine fact but decided a display session, and no host set it true, so it is gone: a fact
  # whose value changes nothing is deleted, not kept for later.
  testHostFactsDeclareNoMachineLabel = {
    expr = builtins.hasAttr "isQemuVM" hostOptions.options;
    expected = false;
  };

  # --- hostLib merge semantics --------------------------------------------
  # mergeModules = lib.foldl' mergeAttrs {}, so it takes ONE list of modules.
  testMergeModulesLaterScalarWins = {
    expr = (hostLib.mergeModules [{a = 1;} {a = 2;}]).a;
    expected = 2;
  };
  testMergeModulesUnionsAndDedupesLists = {
    expr = (hostLib.mergeModules [{l = [1 2];} {l = [2 3];}]).l;
    expected = [1 2 3];
  };
  testMergeModulesDeepMergesNestedAttrsets = {
    expr =
      (hostLib.mergeModules [
        {
          n = {
            x = 1;
            y = 2;
          };
        }
        {n = {y = 3;};}
      ]).n;
    expected = {
      x = 1;
      y = 3;
    };
  };
  # host-lib treats anything with `_type` as a leaf, so a derivation-shaped value beats attrs.
  testMergeModulesDerivationLeafBeatsAttrs = {
    expr = (hostLib.mergeModules [{leaf = {a = 1;};} {leaf = leafStub;}]).leaf._type;
    expected = "derivation";
  };
  testProfilesMergeThroughHostLib = {
    expr = (hostLib.mergeModules (hostLib.profiles ./fixtures/profiles ["a" "b"])).features;
    expected = ["x" "y"];
  };
  # A feature reached through two paths (profile + host) must import ONE module, not two —
  # duplicate imports throw "already declared" at evaluation.
  testMergeModulesDedupesAFeatureReachedTwice = {
    expr = (hostLib.mergeModules [{features = ["a" "b"];} {features = ["a"];}]).features;
    expected = ["a" "b"];
  };

  # --- mergeHome: the footgun that turns a profile into a standalone host --
  # A home-only feature list survives untouched; a `nixos-` one is rejected rather than
  # silently dropped, because dropping it makes a home config that quietly lacks a module.
  testMergeHomeForcesAStandaloneHostRecord = {
    expr = mergeHomeCase.isNixOS;
    expected = false;
  };
  testMergeHomeDropsNixosModules = {
    expr = mergeHomeCase.nixosModules;
    expected = [];
  };
  testMergeHomeKeepsHomeFeatureList = {
    expr = mergeHomeCase.features;
    expected = ["hm-base" "hm-tmux"];
  };
  testMergeHomeClearsAdmin = {
    expr = mergeHomeCase.users.josh.isAdmin;
    expected = false;
  };
  testMergeHomeRejectsANixosFeature = {
    expr = hostLib.mergeHome [{features = ["nixos-kde" "hm-base"];}];
    expectedError = {
      type = "ThrownError";
      msg = "NixOS-only feature";
    };
  };

  # --- the home tier's own contracts --------------------------------------
  # A home configuration is not a NixOS configuration: forcing the toplevel must fail rather
  # than quietly produce something buildable.
  testHomeConfigIsNotANixosConfig = {
    expr = s.flake.outputs.homeConfigurations."josh@methyl-bazzite".config.system.build.toplevel;
    expectedError = {
      type = "EvalError";
      msg = "attribute 'system' missing";
    };
  };
  # A wrapper name outside Home Manager's enum must fail rather than quietly fall back to mesa:
  # the wrong driver set is a runtime failure, not an eval one.
  testUnknownNixglWrapperThrows = {
    expr = (s.hmCfg (s.fixtureHost false ["hm-nixgl"] {nixgl.wrapper = "nvofei";})).features.nixgl.wrapper;
    expectedError = {
      type = "ThrownError";
      msg = "A definition for option `features.nixgl.wrapper' is not of type";
    };
  };
}
