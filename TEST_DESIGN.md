# TEST_DESIGN — eval-only suite

The suite asserts on **evaluated configuration values**, never on built output: `nix eval --impure
--file` forces a config far enough to read option values, and that is the whole cost. No `nix
build` runs, so the gate is fast and works without a store.

## Gate shape

```mermaid
flowchart TD
  R["tests/run.sh"] --> G["green suites<br/>tests/*.nix via nix eval"]
  G --> G1["exit 0 → ok"]
  G --> G2["exit 1 → FAIL + error tail"]
  R --> D["red guards<br/>tests/red/*.nix"]
  D --> D1["must exit non-zero<br/>stderr must contain line-1 expect substring"]
  G1 --> X["exit 0 = repo is green"]
  D1 --> X
```

```mermaid
flowchart LR
  S["tests/support.nix<br/>lib, flake outputs, features, hosts, hostLib,<br/>hostsAt(dir), args, ck, suite"] --> L["tests/loader.nix"]
  S --> C["tests/configs.nix"]
  S --> H["tests/home.nix"]
  S --> O["tests/outputs.nix"]
  S --> F["tests/filesystems.nix"]
  S --> M["tests/mounts.nix"]
  S --> RD["tests/red/*.nix"]
  FX["tests/fixtures/<dir>/hosts/*.nix<br/>shapes no real host uses"] --> L
```

Why two kinds of gate: Nix errors are deferred values, so `builtins.tryEval` cannot catch them.
A guard that must fail is a tiny file whose _exit status_ is the assertion; everything else is a
boolean check inside a suite. Fixture directories exist so loader guards never depend on a real
host changing shape.

## What each suite covers

```mermaid
flowchart TD
  subgraph loader["loader.nix — pure, ~0.2s"]
    L1["feature discovery: features/ dirs == discovered;<br/>hm-* have home.nix; nixos-* have nixos.nix;<br/>overlay-bearing set; resolveFeaturePaths maps each feature to its file"]
    L2["host discovery: names == hosts/; every listed feature resolves;<br/>standalone lists no nixos-*; NixOS hosts carry modules; hmUsernames"]
    L3["fixtures: flat record derives osUsernames/hmUsernames;<br/>directory host auto-discovers nixos.nix + home-*.nix"]
    L4["hostLib: scalar last-wins, list union deduped by first occurrence,<br/>nested attrsets deep, derivation-shaped leaf wins,<br/>profiles merge, mergeHome forces the standalone shape"]
  end
  subgraph configs["configs.nix — forces every NixOS config"]
    C1["per-host facts: hostName, timezone, user shell"]
    C2["universal wiring: tailscale, podman, firefox, printing, wheel"]
    C3["gating: gaming stack only on methyl; gnome/qemu/btrfs only on the VM;<br/>kait2en+fprintd only on the laptop; korthos methyl-only; dms everywhere"]
    C4["cache gate: flakeCache.ready everywhere;<br/>substituters/keys counts == enabled caches; warnings clean"]
  end
  subgraph home["home.nix — forces the standalone HM config"]
    H1["builder facts: username, homeDirectory, genericLinux target"]
    H2["features + packages the profile and the host contribute"]
    H3["nixGL wrapper names; no warnings"]
  end
  subgraph outputs["outputs.nix — reads the output attrsets"]
    O1["outputs are exactly configs + checks"]
    O2["checks keyed by the system each config was built for"]
    O3["one check per configuration, and each is a derivation"]
    O4["configs derived from host records; host name wired into config.flakeHost"]
  end
  subgraph filesystems["filesystems.nix — pure lib, ~0.2s"]
    F1["mkMounts: entry keys win, entry options REPLACE defaults,<br/>subvol appended last, empty option list dropped"]
    F2["mkUnitMounts: string shorthand, options joined to a comma string,<br/>skipIfMissing -> ConditionPathExists, sugar keys removed"]
    F3["automount whitelist: only where/description/wantedBy/unitConfig/<br/>automountConfig, so mount->automount->mount is not an ordering cycle"]
    F4["joinUnitMounts: groups concatenate in order, [] == {}"]
  end
  subgraph mounts["mounts.nix — forces the 3 hosts enabling nixos-automounts"]
    M1["only those hosts have systemd.automounts; every automount has a<br/>mount at the same where (proves where -> unit-name derivation)"]
    M2["that mount requires and after <unit>.automount;<br/>automounts carry no requires/after/wants and no mountConfig"]
    M3["mounts: mountConfig.TimeoutSec 5, ConditionPathExists shared with the<br/>automount; cifs options carry credentials=/etc/.smb-credentials"]
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
  end
```

Coverage rule: assert on **namespaces and values**, not on `enable` flags. A feature's option
defaults are unreliable evidence — several features ship packages without turning a program
option on — so checks look for the service, the package, or the kernel parameter the feature
actually produces.

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
```

Deliberately skipped: per-feature coverage of all 39 modules. Feature modules are exercised
through the hosts that enable them — 36 of 39 are enabled by at least one host, so they evaluate
and their effects are asserted. The three no host enables (`hm-dcal`, `nixos-cachyos`,
`nixos-zram`) have no test: a feature no host asks for is not a shipping contract. If one of them
becomes load-bearing, cover it by enabling it on a fixture host, not by isolating the module.
