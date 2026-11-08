# flakeroot

One Nix flake that builds every machine's config. A host is a file under `hosts/` that lists the
features it wants; the loader discovers it and emits `nixosConfigurations.<host>` and
`homeConfigurations.<user>@<host>`.

## Helpers

Run from the repo root.

| Helper                                                                               | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------- | ------ | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./bootstrap.sh <host>`                                                              | Day zero on a **NixOS** host: `sudo nixos-rebuild boot --install-bootloader --flake .#<host>`. Passes the registry caches as `--option extra-substituters` / `--option extra-trusted-public-keys` so a fresh machine fetches instead of compiling — `--option` survives `sudo` and needs no trusted user. The flag, not an `env` assignment, is what installs the bootloader: nixos-rebuild-ng sets `NIXOS_INSTALL_BOOTLOADER` itself and runs the activation under `env -i`.                                                                                                                                                                                                 |
| `./bootstrap.sh <user>@<host>`                                                       | Day zero on a **non-NixOS** host: `home-manager switch --flake .#<user>@<host>`, same cache injection. Needs a trusted Nix user, which `--standalone` grants.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `./bootstrap.sh --standalone [--install] [--rebind[=DIR]] [<user>@<host>]`           | Prepares a box with **no Nix**: installs it through the pinned upstream installer's `ostree` plan (`--enable-flakes`, plus `--persistence <dir>` when `--rebind` names the volume), then adds this user to `extra-trusted-users` and restarts `nix-daemon`. `--install` also installs Home Manager through its channel — the release the flake's `home-manager` input pins. With no target it prints one status line and stops. `--rebind` is refused when `nix` is already on PATH, because the store bind only happens while the installer runs; clear Determinate first with `sh <(curl -s https://install.determinate.systems/nix) uninstall`. `--help` prints the usage. |
| `features/<name>/update.sh [<ref> \| --check]`                                       | Pins one feature. No arg = latest release; `<ref>` = pin that ref explicitly; `--check` = exit 1 when a newer version exists or the pinned hash moved. A symlink to `lib/updater.sh`, configured by that feature's `metadata.json`.                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `./update-all.sh [--flake] [--check]`                                                | Runs every `features/*/update.sh` (aborts on the first failure), forwards its args to each, then commits `features/` and `flake.lock`. `--flake` also runs `nix flake update`. Stops if any `update.sh` is a copy instead of a symlink, and skips the commit when the tree is dirty beyond those paths.                                                                                                                                                                                                                                                                                                                                                                       |
| `./terraform.sh --emit \| --recipe <file> \| --verify`                               | The only thing here that touches a drive: reads a host's `terraform.json`, reproduces it, re-reads the drive before reporting success. Needs `sfdisk`/`blkid`/`lsblk`/`jq` and the `mkfs.*`, so run it as `nix develop --command bash terraform.sh …`. See **Terraform the drive** below.                                                                                                                                                                                                                                                                                                                                                                                     |
| `./install.sh [--dry-run] [--force] [--root <dir>] [--stage prepare                  | terraform                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | deploy | postdeploy | reboot | all[,<stage>...]] <host>` | Staged installer for a host's drive: `prepare` reads the host and drive and checksums the partition table, `terraform` runs `./terraform.sh` against `hosts/<host>/terraform.json`, `deploy` runs `nixos-install --root <dir>` (refused until `--verify` passes on the drive), `postdeploy` writes ssh keys and passwords into the installed tree, `reboot` only after both. `--stage` takes a comma list, so `--stage prepare,terraform` runs those two in the order given; `all` is the whole sequence. One confirm per stage, asked right before that stage writes (`terraform` asks only when the drive is about to change); `destroy` and `--yes-wipe-all-disks` are never passed. |
| `bash tests/run.sh`                                                                  | Gate. Green suites print `ok tests/<suite>.nix`; the value-tier assertions run as nix-unit test attributes in `tests/suite.nix`, where a must-throw check is an `expectedError` attribute rather than a separate file. Four tiers run `nix build` on synthetic fixtures (`appdir`, `brave-layout`, `shellwrap`, `yazi-install`), so a build failure can come from the gate. See **Test gate** below.                                                                                                                                                                                                                                                                          |
| `bash tests/build-harness.sh [--cap MB] [--build] [--stats] [--link PATH] -- <attr>` | Build-time telemetry for one attribute under one memory scope, running the exact `nix build` command `njust` runs: `peak`/`swap` from the scope, `wall`, and `out`/`installed` with `--build`. Not part of the gate — it builds. See **Build telemetry** in TEST_DESIGN.md.                                                                                                                                                                                                                                                                                                                                                                                                   |

## Test gate

`bash tests/run.sh` runs every suite with `nix eval --impure --file`, one process per suite, plus
one `nix-unit` run of the value-tier assertions, and caps each process with a transient systemd
scope (`MemoryHigh` 90%, `MemoryMax` 1792M, `MemorySwapMax` half that, polled every 0.1s with one
`systemctl show` for `MemoryCurrent`, `MemoryPeak` and `MemorySwapPeak`).
Suites that share nothing but the Nix store run concurrently: the four fixture builds first, inside
their own subshell, and at most three heavy evals in flight; each still
gets its own scope, so the cap bounds one suite and the lane bounds the sum.
Splitting is not cosmetic: a single
`nix flake check --no-build` needs ~2.6GB in one process (measured), and `methyl-bazzite` — 3 GB
free, 3 GB swap — thrashes on a whole-tree eval. Going over the cap is a failure (`exit 137`),
not a hang.

Cost, measured on this host with the cap in force: whole gate ~24s warm, 19 verdict lines green — shell
lint, the devShell tool check (one `nix develop` resolves every tool the gate needs), one `nix-unit`
run of 180 attributes, a concurrent wave of the 4 eval
suites + 4 fixture builds + 3 host configs (they share only the Nix store), the mocked rebuild, the
9 stub bats suites (315 tests) as one parallel `bats --jobs 8`
call, `terraform.bats` (63 tests) at `--jobs 16` inside its own scope, and parity — the two bats
tiers and the lint and parity checks overlap the wave, so the gate costs the slower of them, not the
sum. `run.sh`
prints each eval's peak on its own line (`peak=998MB`), taken from the scope's `MemoryPeak` while
the eval is still alive — a killed eval reports the peak it reached before the OOM. Widest peaks:
`home` ~998MB, `configs` 669–747MB (methyl / methyl-nixos / propyl), `terraform.bats` ~815MB
(16 parallel fixtures, swap 0), `wrap` ~725MB, `mounts` ~365MB, `brave-layout` ~400MB,
`devshell` ~325MB, `outputs` ~300MB; the value tier (`tests/suite.nix`) sits at ~705MB for 180
attributes, and parity at ~21–40MB, which is `nix` startup. Peaks move a few MB run to run.

Four tiers build, on purpose, and none of them fetches what it is testing: `appdir` (~0.3s,
`features/hm-ghostty/_package.nix`'s real installPhase over a synthetic AppDir — `src` is a
placeholder, so no AppImage is ever downloaded), `brave-layout` (~1.6s, the same shape over a synthetic
rpm payload — `features/hm-brave/_package.nix`'s real installPhase re-run, so the store layout that
ships is the layout that is checked), `shellwrap`
(~0.8s, the shipped `writeShellApplication` wrappers, so nixpkgs' shellcheck linting is applied to the
text that ships), and `yazi-install` (~0.7s, the pinned yazi sources unpacked and their `postInstall`
re-run). Nothing else is built, so no tier pulls a kernel, firmware or vendor asset.

**The warning invariant.** A config warning must fail a build, not print one line of text. Every
NixOS config and Home Manager config gets `modules/warnings-gate.nix`, which appends a
`config.assertions` entry asserting `warnings == []`. Assertions are part of the toplevel and HM
activation derivations, so the throw fires when the real config is built; a warning is a mistake
here, not a hint. Reading `config.warnings` costs ~450MB on its own (Nix 2.34 re-warns every
warning string on each access), which is why the gate runs no warnings check at all. The feature
layer has its own rule: a feature may not set `nixpkgs.overlays` and declare an option at the same
time — such a module is never reachable through the loader, since nixpkgs instantiates an overlay
before the config that gates it. `tests/warnings.nix` pins the gate and `tests/loader.nix`'s
`testEveryOverlaysNixIsAModule` pins the layer rule; the config layer itself is tested in
`tests/configs.nix`.

## Deploy

```bash
export NH_FLAKE="$HOME/.config/flakeroot"   # tells nh which flake to build
./bootstrap.sh propyl                        # day zero on a fresh NixOS host
./bootstrap.sh --standalone --install josh@bazzite  # day zero on a box with no Nix
nh os switch                                 # day 2+: NixOS system + Home Manager
nh home switch                               # day 2+: Home Manager only
nix flake show                               # list discovered configs
```

A Home-Manager-only host (e.g. Bazzite) has no `nixos-rebuild` step — switch it with `nh home switch`
once Nix is installed.

After a NixOS switch, `/etc/nix/nix.conf` carries the caches from `flakeCache.enable`, so plain
`nh os switch` is enough from then on. Set `flakeCache.enable = []` to build everything locally.

## Terraform the drive (`terraform.sh`)

`terraform.sh` is the only thing this repo lets touch a drive (ADR-b77ec913151f), and
`hosts/<host>/terraform.json` is the layout it acts on — the recipe replaced the flags that named a
filesystem and a device path. Its tools come from the devShell (`util-linux`, `gptfdisk`,
`dosfstools`, `e2fsprogs`, `btrfs-progs`, `xfsprogs`, `jq`), so the invocation is
`nix develop --command bash terraform.sh …`. `install.sh --stage terraform` runs it with
`--recipe <file> --disk <device> --mount <root>`, and `--stage deploy` refuses to install until
`--verify` passes on the same drive.

```bash
./terraform.sh --emit [--disk <drive>]              # read-only: the recipe this drive describes
./terraform.sh --dry-run --recipe <file>            # plan only: "<name>: adopt" / "<name>: format <fs>"
./terraform.sh --recipe <file> [--mount <dir>]      # reproduce it, one confirm per destructive step
./terraform.sh --recipe <file> --verify             # verdict: "terraform: recipe satisfied on <drive>"
./terraform.sh --recipe <file> --record             # fold: the drive's UUIDs into <mount>/terraform.json
```

**Writing the file.** `--emit` prints JSON on stdout alone and every human decision on stderr, so
`./terraform.sh --emit > hosts/<host>/terraform.json` is the workflow. One entry per partition whose
`blkid` signature is `ext4`/`vfat`/`btrfs`; a blank partition carries no intent and is never guessed,
so each partition left out is named on stderr (`left out basic-data (ntfs) linux (no filesystem)`).
Size is exact bytes reduced to the largest whole unit, `mount` is a guess (largest filesystem as `/`,
vfat as `/boot`), `options` are terraform.sh's per-filesystem defaults, `type` is never emitted
(`default_type` derives the ESP or Linux GUID from `fs`), and `owns` is always `false` — claiming a
drive is what makes a run destructive, so flipping it is a deliberate edit. It writes **no JSON** and
exits 2 on no partition table, nothing reproducible, more than one disk, or `--emit --recipe`. The
one thing a drive cannot show is the partition you intend to create, so expect one hand edit:

```bash
jq '.partitions += [{name: "root", label: "nixos", fs: "ext4", size: "rest", mount: "/"}]' \
  emitted.json > hosts/<host>/terraform.json
```

**Schema.**

| field        | rules                                                                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `owns`       | `true` reproduces the layout from zero, `false` adopts what exists and appends. Must equal `flakeHost.ownsWholeDisk` — `install.sh` refuses the mismatch, and refuses an owning host with no file at all.     |
| `disk`       | optional `/dev/disk/by-id/...`; only meaningful on a drive with nothing to identify it by, and must resolve (`realpath -e`). `owns: true` always needs it (`--disk` also works): a wipe cannot be discovered. |
| `partitions` | layout order. Exactly one entry mounts `/`, and that entry must carry a `label` — mkfs is what creates it.                                                                                                    |

| entry field | rules                                                                                                                                                                                                                                                                                                             |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`      | handle printed in the plan and by `--emit` (lowercased label, anything else folded to `-`; `esp` for an unlabeled vfat, `p<N>` otherwise). Not a device name.                                                                                                                                                     |
| `label`     | filesystem label, written by `mkfs -L`/`-n` and compared by `--verify`. Omit where the filesystem has none — a foreign ESP is found by its `vfat` signature or GPT type.                                                                                                                                          |
| `fs`        | `ext4`, `vfat`, `btrfs`, `xfs`. Anything else refuses: terraform.sh does not format it.                                                                                                                                                                                                                           |
| `size`      | bytes, `K`/`M`/`G`, or `rest`. Required when a partition has to be created, and on every entry when `owns: true`; omitted means "adopt whatever it is". `rest` takes what is left of the last gap — a second `rest` gets nothing and refuses.                                                                     |
| `type`      | sfdisk typecode (`EF00`, `83`) or GUID, compared as a GUID against `sfdisk --json`. This is the partition _type_, not `PARTUUID`.                                                                                                                                                                                 |
| `mount`     | `/` makes the entry the root, `vfat` makes it the ESP. `--mount` (default `/mnt`) must resolve to the root entry.                                                                                                                                                                                                 |
| `uuid`      | the filesystem UUID, read back off the drive by `--record`. It names one filesystem where a label is unique only within one drive; `--verify` refuses a UUID the drive no longer carries, and a UUID on a partition this run would format refuses, because `mkfs` invents one.                                    |
| `options`   | comma list, no spaces. Defaults per filesystem (`ext4` `noatime`, `btrfs` `noatime,compress=zstd`, `xfs` `noatime,logbsize=256k,noquota`, `vfat` `fmask=0077,dmask=0077`); `"options": ""` means the kernel's, not the fallback. Btrfs-only options on a non-btrfs entry, or xfs-only on a non-xfs entry, refuse. |

Btrfs subvolumes are **not** in the recipe: `create_subvolumes` builds the tree the layout mounts
(`@`, `@home`, `@nix`, `@log`, `@cache`, `@snapshots`, `@swap`) and adopts one that already exists.

**Two modes.** `owns: true` refuses a DOS table, a filesystem signature across the whole drive, and any
partition signature no entry claims — a mis-declared shared drive cannot be wiped. It writes a fresh GPT
only when the table is not already exactly the layout, then labels, formats, mounts, and verification
requires the table to hold exactly the recipe's entries. `owns: false` resolves each entry in one order
and never guesses — label, then signature + GPT type, then a blank partition carrying the entry's GPT
`name`, then create into the first 1MiB-aligned gap large enough. Two entries claiming one partition is a
recipe contradiction; free-space maths is settled before a single write, so "it does not fit" exits 2
naming needed against free. Resize is never attempted in either direction, and the entries that already
existed are compared before and after, so a moved partition is a failure rather than a side effect.

A host's partition mounts **are** the recipe: `lib/filesystems.nix` `mountsFromRecipe` turns every
mounted entry into a `fileSystems` item — label to `/dev/disk/by-label/`, `fs` to `fsType`, the
entry's `options` split on commas (`""` means the kernel's) — and an entry with no `mount` is created
but never mounted. An entry that mounts with no label, or two entries claiming one mount point, throws
at eval instead of dropping a mount silently. The btrfs subvolume tree stays host-side, as above:
`hosts/<name>/nixos.nix` derives those mounts from the recipe's **root** entry with
`fsLib.mkMounts mounts."/"`, so each one inherits the root's device, fsType and options and adds
`subvol=@<name>`.

Options have two homes and one rule. The recipe is what `terraform.sh` mounts the drive with; the
config's `fileSystems` is what NixOS mounts at boot. Appending an option to the recipe reaches both.
Appending one to a single mount is `fsLib`'s `extraOptions`, which adds to whatever is there; an
entry's `options` **replaces** the defaults rather than merging them, so overriding means restating
the whole list — including any `subvol=…` — and overriding a recipe-derived mount's options is the
one way the two sides can disagree (`tests/configs.nix` does not catch that).

The recipe is checked against the config it describes: `tests/configs.nix` asserts `owns` equals
`flakeHost.ownsWholeDisk`, that every derived mount carries the recipe's device and fsType, and that
every mount the recipe does not name is a btrfs subvolume of the recipe's labelled root. A partition that exists on the
drive but is missing from the recipe shows up as a deploy failure: `install.sh --stage deploy` refuses
to install until `terraform.sh --recipe <file> --verify` passes on the drive, and `--emit` regenerates
the file from the drive.

**Recording the UUIDs.** A recipe that declares no `uuid` names filesystems by label, and two drives can
answer to one label. `install.sh --stage terraform` calls `--record` as its last act, after the
reproduction and its checks came back clean, so the recipe carrying this drive's UUIDs lands on the
target root filesystem (it becomes `/terraform.json` on the installed host) and a run that failed leaves
no recipe behind. Folding it into the repo is the operator's act — `cp /terraform.json
hosts/<host>/terraform.json`, then `nix flake check` — and `--stage deploy` refuses until the host
recipe carries them. A recipe that already declares every UUID has nothing to fold, so the stage says
nothing about it.

## Hosts

| Path                                                     | Kind                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| `hosts/<name>.nix`                                       | Home-Manager-only host — build the record with `hostLib.mergeHome` |
| `hosts/<name>/default.nix`                               | NixOS host — build the record with `hostLib.mergeModules`          |
| `hosts/<name>/nixos.nix`, `hosts/<name>/home-<user>.nix` | Extra modules, picked up automatically                             |

Host options:

| Option                               | Default    | Meaning                                                                      |
| ------------------------------------ | ---------- | ---------------------------------------------------------------------------- |
| `system`                             | —          | required, e.g. `x86_64-linux`                                                |
| `isNixOS`                            | `false`    | build a NixOS system for this host                                           |
| `features`                           | `[]`       | feature names from `features/` — the single source of truth                  |
| `users.<name>.enabled`               | `true`     | include the user in `osUsernames`                                            |
| `users.<name>.isAdmin`               | `false`    | add `wheel` to `extraGroups`; meaningless on a HM-only host                  |
| `users.<name>.hmEnabled`             | `true`     | `false` creates the NixOS user but skips its home config                     |
| `ownsWholeDisk`                      | `false`    | the drive is NixOS's alone, so `terraform.json` may partition the whole disk |
| `nixosModules`, `homeModules.<user>` | `[]`, `{}` | extra module paths beyond the features                                       |

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
- `_overlays.nix` is a **module** — `{config, lib, inputs, ...}: { config.nixpkgs.overlays = …; }`,
  not a bare overlay function. A file returning `[ final: prev: … ]` contributes nothing: the loader
  feeds modules to nixpkgs, and only a module can be gated on a feature option (`tests/loader.nix`
  pins the shape). Keep the overlay itself lazy (`final: prev: …`) and never force `pkgs.*` at top
  level
- a feature that pins a package keeps `metadata.json`, `_package.nix`, and an `update.sh` symlink;
  a derivation reads flake packages through `flakePackages.<name>.<system>.default`, not an `inputs`
  closure

See `DESIGN.md` for the loader's data flow.
