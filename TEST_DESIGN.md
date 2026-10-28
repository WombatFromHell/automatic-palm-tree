# TEST_DESIGN — eval-only suite

The suite asserts on **evaluated configuration values**, never on built output: `nix eval --impure
--file` forces a config far enough to read option values, and that is the whole cost. No `nix
build` runs, so the gate is fast and works without a store.

## Gate shape

```mermaid
flowchart TD
  R["tests/run.sh"] --> N["tests/nix-eval.sh<br/>transient systemd scope per eval<br/>(MemoryMax / MemoryHigh / MemorySwapMax)<br/>peak= reported on stderr"]
  N --> G["green suites<br/>tests/*.nix via nix eval"]
  G --> G1["exit 0 → ok"]
  G --> G2["exit 1 → FAIL + error tail"]
  R --> C["configs.nix, one host per process<br/>TEST_HOST = methyl | methyl-nixos | propyl"]
  C --> G1
  R --> D["red guards<br/>tests/red/*.nix"]
  D --> D1["must exit non-zero<br/>stderr must contain line-1 expect substring"]
  R --> P["expander parity<br/>one nix eval lists every features/*/metadata.json x pinned system;<br/>bash expands the same list through render_url and diffs byte-for-byte"]
  R --> B["bootstrap.sh invariant<br/>grep: --install-bootloader present,<br/>no env NIXOS_INSTALL_BOOTLOADER"]
  G1 --> X["exit 0 = repo is green"]
  D1 --> X
  P --> X
  B --> X
```

Style is outside the gate: `statix check .` and `alejandra --check .` are run by hand (or CI), not
by `tests/run.sh`.

```mermaid
flowchart LR
  S["tests/support.nix<br/>lib, flake outputs, features, hosts, hostLib,<br/>hostsAt(dir), featuresAt(dir), hasPkg, ck, suite,<br/>assertWarnStubs, failingAssertions"] --> L["tests/loader.nix"]
  S --> CA["tests/caches.nix<br/>bare module eval of modules/caches.nix"]
  S --> WA["tests/warnings.nix<br/>bare module eval of modules/warnings-gate.nix"]
  S --> C["tests/configs.nix"]
  S --> H["tests/home.nix"]
  S --> O["tests/outputs.nix"]
  S --> F["tests/filesystems.nix"]
  S --> M["tests/mounts.nix"]
  S --> PI["tests/pins.nix"]
  S --> RD["tests/red/*.nix"]
  FX["tests/fixtures/<dir>/hosts/*.nix<br/>shapes no real host uses"] --> L
```

Why two kinds of gate: Nix errors are deferred values, so `builtins.tryEval` cannot catch them.
A guard that must fail is a tiny file whose _exit status_ is the assertion; everything else is a
boolean check inside a suite. Fixture directories exist so loader guards never depend on a real
host changing shape.

Each suite runs in its own process inside a transient systemd scope (`MemoryMax`, `MemoryHigh` at
90% of it, `MemorySwapMax` at half of it; RSS polled every 20ms — systemd only reports
`MemoryPeak` while the unit is alive, so a peak read after the scope exits is gone). Swap is
_capped_, not forbidden: with `MemorySwapMax=0` an allocation that cannot be met from free RAM
stalls instead of being killed, and the gate hung on this box.

Splitting is not cosmetic: forcing three host configs in one eval peaks at ~2.1GB, and a single
`nix flake check --no-build` needs ~2.6GB (measured), both over the 1792MB cap — hence
`configs.nix` runs one host per process. Going over the cap is a failure (exit 137), not a hang.
`run.sh` prints each eval's `peak=` on its line. Measured today: the whole gate ~21s, largest
per-eval peak ~850MB (a host's config), pure suites under 50MB.

## What each suite covers

```mermaid
flowchart TD
  subgraph loader["loader.nix — pure, ~0.2s"]
    L0["hasPkg contract: pname shape, name shape, a miss,<br/>and a hit that forces nothing after it"]
    L1["feature discovery: features/ dirs == discovered;<br/>hm-* have home.nix; nixos-* have nixos.nix;<br/>overlay-bearing set; resolveFeaturePaths maps each feature to its file;<br/>a symlinked feature dir is discovered"]
    L2["host discovery: names == hosts/; every listed feature resolves;<br/>standalone lists no nixos-*; NixOS hosts carry modules; hmUsernames;<br/>adminUsernames derives from isAdmin on enabled users"]
    L3["fixtures: flat record derives osUsernames/hmUsernames;<br/>directory host auto-discovers nixos.nix + home-*.nix;<br/>symlinked nixos.nix/home-*.nix are discovered;<br/>a declared homeModules.<user> keeps the discovered home-<user>.nix"]
    L4["hostLib: scalar last-wins, list union deduped by first occurrence,<br/>nested attrsets deep, derivation-shaped leaf wins,<br/>profiles merge, mergeHome forces the standalone shape"]
  end
  subgraph configs["configs.nix — forces every NixOS config"]
    C1["per-host facts: hostName, timezone, user shell"]
    C2["universal wiring: tailscale, podman, firefox, printing, wheel"]
    C3["gating: gaming stack only on methyl; gnome/qemu/btrfs only on methyl-nixos;<br/>kait2en+fprintd only on propyl; korthos methyl-only; dms everywhere;<br/>absence read from namespace/systemd-unit/option, never by scanning the package list;<br/>the positive side of every absence signal is asserted too, so absence is not vacuous"]
    C4["cache gate: flakeCache.ready everywhere;<br/>substituters/keys counts == enabled caches;<br/>the caches each host's features actually require (nix-community, kait2en,<br/>wombatfromhell only where niri-spicy is on)"]
    C5["kernel: which kernel each host boots, incl. the kait2en kernel<br/>the feature pins rather than boot.kernelPackages"]
  end
  subgraph home["home.nix — forces the standalone HM config"]
    H1["builder facts: username, homeDirectory, genericLinux target"]
    H2["features + packages the profile and the host contribute;<br/>hm-base ships packages, not program flags"]
    H3["nixGL wrapper names"]
  end
  subgraph outputs["outputs.nix — reads the output attrsets"]
    O1["outputs are exactly configs + checks"]
    O2["checks keyed by the system each config was built for"]
    O3["one check per configuration, and each is a derivation"]
    O4["configs derived from host records; host name wired into config.flakeHost"]
  end
  subgraph caches["caches.nix — bare module eval of modules/caches.nix"]
    CA1["a required cache the host does not enable is warned by name,<br/>including the fix line; an enabled one warns nothing"]
    CA2["ready false while a required cache is disabled, true when enabled or when nothing is required"]
    CA3["a required cache outside the registry fails an assertion"]
    CA4["substituters and keys come from the enabled caches in order; [] means none"]
  end
  subgraph filesystems["filesystems.nix — pure lib, ~0.2s"]
    F1["mkMounts: entry keys win, entry options REPLACE defaults,<br/>subvol appended last, empty option list dropped"]
    F2["mkUnitMounts: string shorthand, options joined to a comma string,<br/>skipIfMissing -> ConditionPathExists, sugar keys removed"]
    F3["automount whitelist: only where/description/wantedBy/unitConfig/<br/>automountConfig, so mount->automount->mount is not an ordering cycle"]
    F4["joinUnitMounts: groups concatenate in order, [] == {}"]
  end
  subgraph mounts["mounts.nix — forces the 3 hosts enabling nixos-automounts"]
    M1["only those hosts have systemd.automounts; every automount has a<br/>mount at the same where (proves where -> unit-name derivation)"]
    M2["that mount requires and after <unit>.automount;<br/>automounts carry no requires/after/wants and no mountConfig;<br/>automounts are wanted by multi-user.target"]
    M3["mounts: mountConfig.TimeoutSec 5, ConditionPathExists shared with the<br/>automount; cifs options carry credentials=/etc/.smb-credentials"]
  end
  subgraph pins["pins.nix — pin metadata contract, ~0.1s"]
    PN1["metadata-backed features discovered; templates use only<br/>the tokens both expanders know ({repo} {version} {arch})"]
    PN2["every pin expands to a resolved url for every pinned system;<br/>a declared arches set covers exactly the hashed systems and is a set, never null"]
    PN3["features/<name>/update.sh is absent or a symlink to lib/updater.sh<br/>the key is quoted — .update.sh would walk update then sh"]
  end
  subgraph warnings["warnings.nix — bare module eval"]
    W1["modules/warnings-gate.nix: assertion true with no warnings,<br/>false with one, and its message carries every warning verbatim"]
  end
```

```mermaid
flowchart LR
  subgraph red["red/*.nix — must throw"]
    R1["unknown feature name"]
    R2["two host files resolving to one name"]
    R3["host file written as a module instead of a record"]
    R4["host file authoring a derived name"]
    R5["mergeHome handed a nixos-* feature"]
    R6["a home configuration has no NixOS system"]
    R7["mkMounts options is a string, not a list"]
    R8["mkUnitMounts options is a string, not a list"]
    R9["mkMounts entry is a string, not an attrset"]
    R10["mkUnitMounts entry is a number, not an attrset"]
    R11["skipIfMissing without what (ConditionPathExists needs the device)"]
    R12["two kernel-pinning features on one host<br/>(boot.kernelPackages would be defined twice)"]
  end
```

Coverage rule: assert on **namespaces and values**, not on `enable` flags. A feature's option
defaults are unreliable evidence — several features ship packages without turning a program
option on — so checks look for the service, the package, or the kernel parameter the feature
actually produces.

Warnings and host assertions are **build-time** signals, and forcing either one evaluates a
host's whole module config (~2.0GB here): `config.assertions` forces `config.warnings`, and
`lib.asserts.checkAssertWarn` throws on failed assertions while printing warnings. So
`modules/warnings-gate.nix` asserts `config.warnings == []` and the build tier (`nix build`,
`nix flake check`, `nixos-rebuild switch`) fails on any warning; no eval suite may force
`config.assertions` or `config.warnings` of a real host. The gate's own logic is covered on a
bare `lib.evalModules` (`tests/warnings.nix`), as is the house warning (`tests/caches.nix`).

## What we do not cover

```mermaid
flowchart TD
  N["not covered"] --> N1["anything a build would prove:<br/>derivation contents, hashes, runtime behavior.<br/>Checks are asserted with isDerivation only"]
  N --> N2["installability: hardware-configuration.nix,<br/>bootloader, disk layout — host-local files, never evaluated"]
  N --> N3["isolated home feature modules: every HM module needs HM's own<br/>option namespace, so isolation needs option declarations that<br/>duplicate HM. Coverage comes from the real host config instead,<br/>which evaluates all home-bearing features together"]
  N --> N4["secrets: agenix needs age keys, so idPath identities are<br/>asserted structurally, not decrypted"]
  N --> N5["network cache availability: bootstrap.sh reads the registry;<br/>whether a cache answers is not a configuration value"]
  N --> N6["other architectures: every host is x86_64-linux,<br/>so pin-meta's per-system boundaries are not exercised"]
  N --> N7["assertion text: NixOS assertions are data on .config.assertions,<br/>they never throw at eval, so we assert the collected list"]
  N --> N8["warnings observed at eval: they go to the CLI, not into a derivation log.<br/>The build tier fails them via modules/warnings-gate.nix"]
```

Deliberately skipped: per-feature coverage of all 39 modules. Feature modules are exercised
through the hosts that enable them — 37 of 39 are enabled by at least one host (`nixos-zram` is
commented out in `hosts/methyl-base/base.nix`, `hm-dcal` is listed nowhere), so they evaluate
and their effects are asserted. The two no host enables have no test: a feature no host asks for
is not a shipping contract. If one of them becomes load-bearing, cover it by enabling it on a
fixture host, not by isolating the module. Kernel choice is the exception:
`nixos-cachyos` and `nixos-kait2en` both write `boot.kernelPackages`, so listing both on one host
is an authoring error — `lib/features.nix` throws on it (`tests/red/kernel-feature-collision.nix`)
and `tests/configs.nix` asserts which kernel each host boots.
