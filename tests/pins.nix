# nix-unit attributes for the pin metadata contract in lib/pin-meta.nix.
#
# lib/pin-meta.nix expands the release-asset URL template in Nix; lib/updater.sh render_url
# expands the same template in bash. The two cannot share code across runtimes, so these
# attributes pin the CONTRACT both sides implement: the token set, and the fact that expanding a
# real pin leaves nothing unresolved. Byte-identical output of the two expanders is gated by
# tests/run.sh, which expands every features/*/metadata.json x pinned system through both sides
# and diffs them.
let
  s = import ./support.nix;
  inherit (s) lib;
  pinMeta = import ../lib/pin-meta.nix {inherit lib;};

  features = builtins.attrNames (builtins.readDir ../features);
  pinned = lib.filter (f: builtins.pathExists ../features/${f}/metadata.json) features;

  pin = f: builtins.fromJSON (builtins.readFile ../features/${f}/metadata.json);

  # Every token the template uses, as `{name}`. splitString rather than a regex:
  # builtins.match rejects `{` escapes and only ever returns the first capture.
  tokens = url:
    lib.filter (t: t != "")
    (map (chunk: builtins.head (lib.splitString "}" chunk)) (builtins.tail (lib.splitString "{" url)));

  # `"arches": null` is a shape lib/pin-meta.nix cannot use — `pin.arches or {}` only fires on a
  # missing key, so a present null reaches attrNames and throws at eval. bash's
  # `jq '.arches[$s] // ""'` would silently render an empty token instead.
  fixturePin = file: builtins.fromJSON (builtins.readFile ./fixtures/${file});
in
  {
    testMetadataBackedFeaturesAreDiscovered = {
      expr = pinned != [];
      expected = true;
    };
    # {repo} {version} {arch} is the whole vocabulary; a new token means lib/updater.sh
    # render_url silently leaves it in the URL it fetches.
    testTemplatesUseOnlyTheTokensBothExpandersKnow = {
      expr = lib.all (f:
        lib.all (t: lib.elem t ["repo" "version" "arch"]) (tokens (pin f).url))
        pinned;
      expected = true;
    };
    # lib/pin-meta.nix releaseAsset must resolve every pinned system with no leftovers.
    testEveryPinExpandsToAResolvedUrlForEveryPinnedSystem = {
      expr = lib.all (f:
        lib.all (system: let
          asset = pinMeta.releaseAsset (pin f) system;
        in
          (lib.hasPrefix "https://" asset.url) && (!(lib.elem "{" (lib.splitString "" asset.url))))
        (pinMeta.pinnedSystems (pin f)))
        pinned;
      expected = true;
    };
    testArchesIsAbsentOrASet = {
      expr = lib.all (f: lib.isAttrs ((pin f).arches or {})) pinned;
      expected = true;
    };
    # features/<name>/update.sh is a symlink to lib/updater.sh. update-all.sh refuses a copy at
    # update time, but nothing gated the invariant, so a hand-copied script drifted silently
    # until its pin did. Absent (a feature with no pin) is fine; lib/updater.sh --install links
    # it. The key is quoted: `.update.sh` would walk `update` then `sh` and find nothing.
    testEveryUpdateShIsTheSharedSymlink = {
      expr = lib.all
        (f: let
          t = (builtins.readDir ../features/${f})."update.sh" or null;
        in
          t == null || t == "symlink")
        features;
      expected = true;
    };

    # --- what pinned metadata must reject (fixture metadata.json, nothing fetched) ---
    # A hash pinned for a system `arches` never declared is a key nobody can resolve an asset URL
    # for, so the boundary names both lists.
    testHashForUndeclaredArchThrows = {
      expr = pinMeta.pinnedSystems (fixturePin "pin-hash-only-arch.json");
      expectedError = {
        type = "ThrownError";
        msg = "pins 'aarch64-linux' in hashes but arches declares only";
      };
    };
    # A second architecture declared in `arches` with no hash must name that system, not surface
    # later as a platform error in nixpkgs.
    testSecondArchWithoutHashThrows = {
      expr = pinMeta.pinnedSystems (fixturePin "pin-two-arch.json");
      expectedError = {
        type = "ThrownError";
        msg = "declares 'aarch64-linux' in arches but no hash is pinned";
      };
    };
  }
