# Pin metadata contract. lib/pin-meta.nix expands the release-asset URL template in
# Nix; lib/updater.sh render_url expands the same template in bash. The two cannot
# share code across runtimes, so this suite pins the CONTRACT both sides implement:
# the token set, and the fact that expanding a real pin leaves nothing unresolved.
# Byte-identical output of the two expanders is gated by tests/run.sh, which expands
# every features/*/metadata.json x pinned system through both sides and diffs them.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;
  pinMeta = import ../lib/pin-meta.nix {inherit lib;};

  features = builtins.attrNames (builtins.readDir ../features);
  pinned = lib.filter (f: builtins.pathExists ../features/${f}/metadata.json) features;

  pin = f: builtins.fromJSON (builtins.readFile ../features/${f}/metadata.json);

  # Every token the template uses, as `{name}`. splitString rather than a regex:
  # builtins.match rejects `{` escapes and only ever returns the first capture.
  tokens = url:
    lib.filter (t: t != "")
    (map (chunk: builtins.head (lib.splitString "}" chunk)) (builtins.tail (lib.splitString "{" url)));
in
  suite "pins" [
    (ck "metadata-backed features are discovered" (pinned != []))

    # {repo} {version} {arch} is the whole vocabulary; a new token means lib/updater.sh
    # render_url silently leaves it in the URL it fetches.
    (ck "templates use only the tokens both expanders know"
      (lib.all (f:
        lib.all (t: lib.elem t ["repo" "version" "arch"]) (tokens (pin f).url))
      pinned))

    # lib/pin-meta.nix releaseAsset must resolve every pinned system with no leftovers.
    (ck "every pin expands to a resolved url for every pinned system"
      (lib.all (f:
        lib.all (system: let
          asset = pinMeta.releaseAsset (pin f) system;
        in
          (lib.hasPrefix "https://" asset.url) && (!(lib.elem "{" (lib.splitString "" asset.url))))
        (pinMeta.pinnedSystems (pin f)))
      pinned))

    # lib/updater.sh documents `arches` as optional (a single-arch tarball URL has no {arch}),
    # so the boundary is: when arches is declared, it covers exactly the hashed systems.
    # That is the invariant pin-meta.pinnedSystems throws on.
    (ck "a declared arches set covers exactly the hashed systems"
      (lib.all
        (f: let
          arches = (pin f).arches or {};
        in
          arches == {} || (lib.attrNames arches == lib.attrNames (pin f).hashes))
        pinned))

    # `"arches": null` is a shape lib/pin-meta.nix cannot use — `pin.arches or {}` only
    # fires on a missing key, so a present null reaches attrNames and throws at eval.
    # bash's `jq '.arches[$s] // ""'` would silently render an empty token instead.
    (ck "arches is absent or a set"
      (lib.all (f: lib.isAttrs ((pin f).arches or {})) pinned))
  ]
