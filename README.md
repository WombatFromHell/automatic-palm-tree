# flakeroot

One Nix flake that builds every machine's config. A host is a file under `hosts/` that lists the
features it wants; the loader discovers it and emits `nixosConfigurations.<host>` and
`homeConfigurations.<user>@<host>`.

## Helpers

Run from the repo root.

| Helper                                         | What it does                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./bootstrap.sh [init] <host>`                 | Day zero on a **NixOS** host: `sudo nixos-rebuild boot --flake .#<host>`. Passes the registry caches as `--option extra-substituters` / `--option extra-trusted-public-keys` so a fresh machine fetches instead of compiling — `--option` survives `sudo` and needs no trusted user.                    |
| `features/<name>/update.sh [<ref> \| --check]` | Pins one feature. No arg = latest release; `<ref>` = pin that ref explicitly; `--check` = exit 1 when a newer version exists or the pinned hash moved. A symlink to `lib/updater.sh`, configured by that feature's `metadata.json`.                                                                     |
| `./update-all.sh [--flake] [--check]`          | Runs every `features/*/update.sh` (aborts on the first failure), forwards its args to each, then commits `features/` and `flake.lock`. `--flake` also runs `nix flake update`. Stops if any `update.sh` is a copy instead of a symlink, and skips the commit when the tree is dirty beyond those paths. |
| `bash tests/run.sh`                            | Eval-only gate on the loader. Green suites print `ok tests/<suite>.nix`; each `tests/red/` guard must throw a message containing its first line (`# expect: <substring>`). Never runs `nix build`.                                                                                                      |

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
