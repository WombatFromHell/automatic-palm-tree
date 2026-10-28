# flakeroot

One Nix flake that builds every machine's config. A host is a file under `hosts/` that lists the
features it wants; the loader discovers it and emits `nixosConfigurations.<host>` and
`homeConfigurations.<user>@<host>`.

## Helpers

Run from the repo root.

| Helper                                         | What it does                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./bootstrap.sh [init] <host>`                 | Day zero on a **NixOS** host: `sudo nixos-rebuild boot --install-bootloader --flake .#<host>`. Passes the registry caches as `--option extra-substituters` / `--option extra-trusted-public-keys` so a fresh machine fetches instead of compiling — `--option` survives `sudo` and needs no trusted user. The flag, not an `env` assignment, is what installs the bootloader: nixos-rebuild-ng sets `NIXOS_INSTALL_BOOTLOADER` itself and runs the activation under `env -i`.                    |
| `features/<name>/update.sh [<ref> \| --check]` | Pins one feature. No arg = latest release; `<ref>` = pin that ref explicitly; `--check` = exit 1 when a newer version exists or the pinned hash moved. A symlink to `lib/updater.sh`, configured by that feature's `metadata.json`.                                                                     |
| `./update-all.sh [--flake] [--check]`          | Runs every `features/*/update.sh` (aborts on the first failure), forwards its args to each, then commits `features/` and `flake.lock`. `--flake` also runs `nix flake update`. Stops if any `update.sh` is a copy instead of a symlink, and skips the commit when the tree is dirty beyond those paths. |
| `bash tests/run.sh`                            | Eval-only gate. Green suites print `ok tests/<suite>.nix`; each `tests/red/` guard must throw a message containing its first line (`# expect: <substring>`). Never runs `nix build`. See **Test gate** below.                                                                                                      |

## Test gate

`bash tests/run.sh` runs every suite with `nix eval --impure --file`, one process per suite, and
caps each process with a transient systemd scope (`MemoryHigh` 90%, `MemoryMax 1792M`,
`MemorySwapMax` half that, RSS polled every 40ms). Splitting is not cosmetic: a single
`nix flake check --no-build` needs ~2.6GB in one process (measured), and `methyl-bazzite` — 3 GB
free, 3 GB swap — thrashes on a whole-tree eval. Going over the cap is a failure (`exit 137`),
not a hang.

Cost, measured on this host with the cap in force: whole gate ~18s, 24 checks green. `run.sh`
prints each eval's peak on its own line (`peak=715MB`), taken from the scope's `MemoryPeak` while
the eval is still alive — a killed eval reports the peak it reached before the OOM. Widest peaks:
`configs` 715MB (methyl) / 790MB (methyl-nixos) / 740MB (propyl), `outputs` 482MB, `home` 396MB,
`mounts` 367MB; the eval-only tiers (`loader`, `filesystems`, `pins`, `warnings`, `caches`, the red
guards, parity) sit at 13–19MB, which is `nix` startup. Nothing on the gate path is ever built, so
no tier pulls a kernel, firmware or package derivation.

**The warning invariant.** A config warning must fail a build, not print one line of text. Every
NixOS config and Home Manager config gets `modules/warnings-gate.nix`, which appends a
`config.assertions` entry asserting `warnings == []`. Assertions are part of the toplevel and HM
activation derivations, so the throw fires when the real config is built; a warning is a mistake
here, not a hint. Reading `config.warnings` costs ~450MB on its own (Nix 2.34 re-warns every
warning string on each access), which is why the gate runs no warnings check at all. The feature
layer has its own rule: a feature may not set `nixpkgs.overlays` and declare an option at the same
time — such a module is never reachable through the loader, since nixpkgs instantiates an overlay
before the config that gates it. `tests/warnings.nix` pins the gate and `tests/red/*.nix` pin the
layer rule; the config layer itself is tested in `tests/configs.nix`.

## Deploy

```bash
export NH_FLAKE="$HOME/.config/flakeroot"   # tells nh which flake to build
./bootstrap.sh propyl                        # day zero on a fresh NixOS host
nh os switch                                 # day 2+: NixOS system + Home Manager
nh home switch                               # day 2+: Home Manager only
nix flake show                               # list discovered configs
```

A Home-Manager-only host (e.g. Bazzite) has no `nixos-rebuild` step — switch it with `nh home switch`
once Nix is installed.

After a NixOS switch, `/etc/nix/nix.conf` carries the caches from `flakeCache.enable`, so plain
`nh os switch` is enough from then on. Set `flakeCache.enable = []` to build everything locally.

## Hosts

| Path                                                     | Kind                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| `hosts/<name>.nix`                                       | Home-Manager-only host — build the record with `hostLib.mergeHome` |
| `hosts/<name>/default.nix`                               | NixOS host — build the record with `hostLib.mergeModules`          |
| `hosts/<name>/nixos.nix`, `hosts/<name>/home-<user>.nix` | Extra modules, picked up automatically                             |

Host options:

| Option                               | Default    | Meaning                                                     |
| ------------------------------------ | ---------- | ----------------------------------------------------------- |
| `system`                             | —          | required, e.g. `x86_64-linux`                               |
| `isNixOS`                            | `false`    | build a NixOS system for this host                          |
| `features`                           | `[]`       | feature names from `features/` — the single source of truth |
| `users.<name>.enabled`               | `true`     | include the user in `osUsernames`                           |
| `users.<name>.isAdmin`               | `false`    | add `wheel` to `extraGroups`; meaningless on a HM-only host |
| `users.<name>.hmEnabled`             | `true`     | `false` creates the NixOS user but skips its home config    |
| `isQemuVM`                           | `false`    | host is a QEMU/KVM VM; features gate hardware choices on it |
| `nixosModules`, `homeModules.<user>` | `[]`, `{}` | extra module paths beyond the features                      |

`name`, `osUsernames`, `adminUsernames` and `hmUsernames` are derived by the loader — a host file that
sets one is rejected.

```nix
# hosts/methyl-bazzite.nix — Home Manager only
{hostLib, ...}: let
  myHome = {pkgs, ...}: {
    home.packages = with pkgs; [cachix pkgs.unstable.herdr];
  };
in
  hostLib.mergeHome (
    hostLib.profiles ./methyl-base ["standalone"]
    ++ [{system = "x86_64-linux"; homeModules.josh = [myHome];}]
  )
```

```nix
# hosts/propyl/default.nix — NixOS, reuses a profile and adds one feature
{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-common"]
  ++ [{features = ["nixos-kait2en"];}]
)
```

`hostLib.profiles <dir> [names]` loads `<dir>/<name>.nix`; `mergeModules` merges them (lists merge by
first occurrence, later records win on scalars), so a variant reuses a profile and states only its
diff. `mergeHome` is `mergeModules` plus `isNixOS = false`, and throws if you list a `nixos-*` feature.
Keep `hardware-configuration.nix` per-host: import it in that host's own `nixos.nix`, never in a shared
profile.

Sibling modules are plain module files: `{config, flakeHost, pkgs, ...}: {…}`, with `pkgs.unstable`
available for packages that need a newer version.

## Features

`features/<name>/` is auto-discovered — no registration. A directory may hold `nixos.nix`, `home.nix`,
and `_overlays.nix`:

- the `nixos-*` / `hm-*` prefix marks the **primary** platform; a feature shipping both files is a
  hybrid (`nixos-kde`, `nixos-oom`)
- a feature a host lists that has no file for that platform is skipped
- `_overlays.nix` is `{inputs, ...}: [ … ]`, applied to `nixpkgs.overlays`; keep it lazy
  (`final: prev: …`) and never force `pkgs.*` at top level
- a feature that pins a package keeps `metadata.json`, `_package.nix`, and an `update.sh` symlink;
  a derivation reads flake packages through `flakePackages.<name>.<system>.default`, not an `inputs`
  closure

See `DESIGN.md` for the loader's data flow.
