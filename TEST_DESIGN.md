# TEST_DESIGN — eval-only suite

The suite asserts on **evaluated configuration values**, never on built output: `nix eval --impure
--file` forces a config far enough to read option values, and that is the whole cost. The
value-tier assertions — the shapes, the loader contracts and everything that must throw — are
`test*` attributes merged into `tests/suite.nix` and run by `nix-unit` in one scoped process.
Nothing else runs a real build, so the gate is fast and works without a store. The exceptions are
deliberate, and each proves something an eval cannot see:

- `tests/appdir.nix` — re-runs hm-ghostty's own `installPhase` over a synthetic AppDir tree built
  from one table (kept, relocated, dropped, left alone), downloading nothing.
- `tests/brave-layout.nix` — re-runs hm-brave's own `installPhase` over a synthetic rpm payload,
  where a copy of a store ELF stands in for the patched binary, because patchelf refuses a text
  file. A copy of a store ELF is the one thing the fixture cannot fake.
- `tests/shellwrap.nix` — builds the three `writeShellApplication` scripts Home Manager ships
  (`credsctl`, `sopsctl`, xilo's wrapper), taken from the feature modules that ship them rather
  than re-declared here, so nixpkgs' shellcheck runs on the text that ships, and the guard cannot
  pass while a module ships something the suites never exercised.
- `tests/yazi-install.nix` — unpacks the two pinned yazi sources and re-runs their real
  `postInstall`, so the assertion is about the revision actually pinned.

`tests/terraform.bats` is the only **byte-level** proof in the gate: real `mkfs`, `blkid`,
`mtools` and `debugfs` against filesystems held in files (see below). Nothing in the gate takes
root.

## Gate shape

```mermaid
flowchart TD
  R["tests/run.sh"] --> N["tests/nix-eval.sh<br/>transient systemd scope per capped step<br/>(MemoryMax / MemoryHigh / MemorySwapMax)<br/>peak= reported on stderr"]
  R --> LN["shipped shell lint<br/>shellcheck over the scripts writeShellApplication never sees:<br/>bootstrap.sh, update-all.sh, lib/updater.sh, lib/cache-check.sh,<br/>lib/style.sh, install.sh, terraform.sh, lib/confirm.sh, the pinentry + nasmount scripts"]
  R --> DV["nix develop resolves the updater and disk tools<br/>curl jq nix bats shellcheck shfmt<br/>+ sfdisk blkid mkfs.vfat mkfs.ext4 mcopy sgdisk"]
  N --> U["tests/suite.nix<br/>nix-unit test* attributes in one process<br/>filesystems, pins, caches, disko, warnings, zram, loader<br/>+ two tripwires; a failing attribute prints its own diff<br/>skip when nix-unit is absent from the devShell"]
  N --> G["eval suites, one process each<br/>tests/home.nix, mounts.nix, outputs.nix, wrap.nix<br/>via nix eval --impure --file"]
  N --> B["fixture builds — the build's exit status is the assertion<br/>appdir, brave-layout, shellwrap, yazi-install"]
  N --> C["configs.nix, one host per process<br/>TEST_HOST = methyl | methyl-nixos | propyl"]
  R --> M["bootstrap.sh mocked rebuild<br/>stub sudo + stub nixos-rebuild report their own cgroup:<br/>the scope wrap is observed, not grepped; plus the no-user-bus fallback"]
  R --> P["expander parity<br/>one nix eval lists every features/*/metadata.json x pinned system;<br/>bash expands the same list through render_url and diffs byte-for-byte"]
  R --> I["stub bats suites, against PATH stubs<br/>bootstrap, build-harness, njust, creds, sopsctl, xilo, updater, install,<br/>cache-check (apps.cache-check's exit codes against a stubbed `nix`)<br/>skip when bats is absent"]
  R --> T["tests/terraform.bats<br/>inside `nix develop`, which carries the disk tools, inside a scope,<br/>bats --jobs: real mkfs/blkid/mtools/sgdisk on sparse images<br/>whose partitions are files; skip when nix, bats or parallel is absent"]
  LN --> X["exit 0 = repo is green"]
  DV --> X
  U --> X
  G --> X
  B --> X
  C --> X
  M --> X
  P --> X
  I --> X
  T --> X
```

An eval suite's verdict is `nix eval`'s exit status: a failing check throws with every failing check
named, and `run.sh` prints the tail of the output on `FAIL`. Only the shell lint and the bootstrap
grep invariant run outside a scope, because neither touches Nix.

Style is outside the gate: `nix run .#apps.<system>.style` (lib/style.sh: every `.nix` through
alejandra + statix, every `.sh`/`.bats` through shfmt + shellcheck, markdown through oxfmt with
`.ank/` excluded by a positional pattern — the corpus is content-addressed, so formatting it would
rewrite decisions rather than prose) is the command, and it is not a gate step because the formatters
rewrite files in place while the gate asserts on evaluated values. `lib/style.sh` itself is linted by
the gate's shipped-shell check.

One suite is not an eval: `tests/bootstrap.bats` asserts the behaviour of `bootstrap.sh` — which
installer flags it picks (`install ostree --enable-flakes --persistence <dir>`), which switch command
it picks for `host` against `user@host`, the flags it refuses, the trusted-user gate and the trust
step's post-check, and the memory-scope probe falling back when `systemd-run` cannot run. Those are
argv and exit codes, not evaluated Nix values, so the suite runs the script against PATH stubs as an
ordinary user: no root, no real `/nix`, no real `curl`, no eval. It costs ~0MB, which is why it is
bash rather than another scoped eval. `bats` comes from the installed Nix profile, so a missing `bats`
is a `skip`, not a failure.

`tests/install.bats` (42 tests) is the same shape for `install.sh`, which is staged destruction: a
NixOS install runs `prepare` → `terraform` → `deploy` → `reboot`. PATH stubs stand in for `lsblk`,
`blkid`, `sfdisk`, `mount`, `nixos-install`, `terraform.sh` and `trivial-run`, so argv and exit codes
are the assertion. It pins that `prepare` reads the host record and checksums the partition table
before and after (a run that moved the table aborts), that the install ISO and the zram swap are
never adopted even when `lsblk` calls them disks, that two candidate drives are refused rather than
guessed, that a host declaring a disko layout or a recipe whose `owns` disagrees with
`flakeHost.ownsWholeDisk` stops before anything runs, that `deploy` refuses before `terraform` and
refuses a drive that no longer matches the recipe, that `deploy` refuses a tmpfs `/mnt` (a closure
built into RAM is not an install), that low RAM is offered as zram rather than thrashed, that one
destructive step asks for one yes, and that `all` refuses the reboot while the installed system has
no password. Nothing here takes root, formats, or installs.

`tests/terraform.bats` (58 tests) is the byte-level half, and it is not stub-driven. The fixtures in
`tests/disk-fixture.bash` are sparse images with a real GPT, sized to the smallest device each
filesystem accepts (ext4 6MB, btrfs ~114MB, xfs ~300MB — each `mkfs` refuses below its own floor),
and built once per file: `sgdisk` costs about a second per call, and the three drives whose tests
only read a filesystem that already exists are formatted in `fixture_setup_file` too, which is what
made the suite slow when images and filesystems were built inside a test. Formatting rewrites the
superblocks, so the holes are punched back out afterwards and every copy into a run directory is
sparse — a copy costs what the filesystem actually wrote, not the whole drive, and the byte-parity
assertions still hold because a sparse copy reproduces every byte. Each partition is extracted with
`dd` to a file named exactly the way `sfdisk` names a node (`<disk>1`). So `blkid`, `mkfs.vfat`,
`mkfs.ext4`, `mkfs.btrfs`, `mtools`, `debugfs` and `sgdisk` all
run for real on paths, with no root and no loop device: a blank partition really gets formatted, and
a partition another OS owns comes back byte-identical. Only `mount` and `findmnt` are stubbed (they
need root), and every tool that could rewrite a partition entry is stubbed to fail, so a partition
write lands on the call log rather than being tolerated. The suite runs `bats --jobs 16` inside a
`terraform` scope — fixtures live on tmpfs, so the only path to the SSD is pages being swapped out,
which is what the sparse copies cut. Geometry is constants both files name: ESP
at 2048..18431, MSR and NTFS only on the Windows shapes, Linux root at 26624..59391, a second Linux
filesystem on the same drive so a run that picks by filesystem type alone can be shown picking the
wrong one, and a root filling the drive so a recipe declaring `rest` has nothing left to take. A
shape that carries a gap keeps its exact size, because the gap is asserted byte for byte. The
ESP carries the ESP GUID (`C12A7328…`), not the FAT32 GUID, because firmware scans by the ESP GUID —
UEFI 2.7 §12.3 — which is what the VM's own ESP carries.

What that suite pins is the drive contract itself (ADR-b77ec913151f): a drive with no partition table
is refused and nothing is formatted; a Windows disk with no Linux partition is refused and left
byte-identical; a Windows disk adopts the ESP and formats only the blank Linux partition; a shared
run plans the partition it would append and writes nothing; a recipe that mounts a non-btrfs
partition with btrfs options, or names a device by UUID when `mkfs` would invent one, refuses before
any write; a second run adopts what the first made and issues no `mount` or `mkfs`; `--verify` reads
the drive against the recipe and refuses, in owns mode, a table holding entries the recipe did not
declare; and `--emit` round-trips — the recipe it prints, run against the same drive, adopts and
writes nothing.

`tests/deploy-loop.sh` is the part none of the above can do, because it needs root: real `losetup`,
real `/dev/loop0pN` nodes, real `mount`, real `nixos-install`. It runs `install.sh --stage all` (the
testing override) against a 4GB sparse image it creates and never touches a real disk, then proves
the recipe reproduces on that drive and that the ESP was adopted rather than rewritten. It is not a
gate step — `tests/run.sh` stays root-free — so it is run by hand:

```bash
sudo nix develop --command bash tests/deploy-loop.sh        # DEPLOY_LOOP_SIZE=8G to override
```

`tests/njust.bats` is the same shape for `features/hm-njust/nix.just`: which attribute and out-link
each scope+mode pair builds, that `activate` builds nothing and refuses a generation that was never
built, that mode `push` uploads the generation already active in a profile — so it takes no target,
no build flag, and no scope that activates on a remote host. Local activation runs as root
(`switch-to-configuration`) or as the user
(home-manager's argument-less `activate`), that a remote deploy copies then sshs and never touches
this host's profile, and that `--with-xilo` pushes once and activates nothing — a push needs a
credential, so the stubbed suite covers the three sources `_push` resolves: an agenix secrets file
(`XILO_SECRETS` points at a temp file, asserted through a recording-only `sudo` stub because the
elevation prefix puts `~/.nix-profile/bin` ahead of the stub dir), the systemd-creds user credentials
`XILO_URL`/`XILO_TOKEN`/`XILO_CACHE` (`CREDENTIALS_DIRECTORY` points at a temp dir with a stub
`systemd-creds`, and a corrupt one must fail loudly), and xilo's saved profile when neither is
present. The stub `nix build` writes a closure at the `--out-link` it was handed, so activation
is driven for real instead of grepped for.

`tests/creds.bats` and `tests/sopsctl.bats` are the same shape for the two credential scripts in
`features/hm-creds`: PATH stubs record argv, so the flags `systemd-creds`, `sops`, `age-keygen` and
`ssh-to-age` really receive are asserted rather than grepped for, and the exit codes are the
assertion (1 usage, 2 no such record, 3 encrypt or decrypt failed). Each suite then runs one
real-binary round trip per backend on the host `PATH` with the stub dir removed — ciphertext the
real `sops` wrote must decrypt back to the same plaintext — and `skip`s when that binary is absent,
so the gate stays green on a host with no sops. Those round trips build their keypairs and their pty
runner once in `fixture_setup_file`, not per test: this tier runs every file's setup before any test,
so per-test setup costs the gate seconds it does not need. `sopsctl.bats` also plants a `ksshaskpass` stub
whose only job is to fail loudly: nothing in `sopsctl` may reach an askpass helper (DESIGN.md's
`hm-creds` section says why), so a key derivation that does is caught here rather than on someone's
terminal. It also drives the passphrase route both ways: an origin whose header says protected is
derived with `SSH_TO_AGE_PASSPHRASE` exported (the variable ssh-to-age actually reads) and with it
absent, where the read must fail and nothing may be written — so the suite pins which input a unit
has and a terminal does not.

`tests/xilo.bats` runs `features/hm-xilo/xilo.sh` with `XILO_PROGRAM` standing in for the CLI, so the
seam is asserted from the outside: the wrapper picks one file per key in priority order (`.sops.json`
ahead of `.sops.yaml`, `.cred` last), adds the bundle record `XILO.sops.json`/`XILO.sops.yaml` in any
case once, fills only the variables xilo did not already have, then execs `credsctl decrypt --env
<names> -- <CLI>` so credsctl decrypts and the CLI inherits the variables — argv, the child's
environment, and the CLI's exit status are asserted against a stub CLI, never inferred. The wrapper
names no `systemd-creds`, KWallet, `SSH_ASKPASS` or `DISPLAY`, which is asserted by grepping the script
itself; with no `credsctl` on PATH the environment passes through untouched, the fallback that keeps
plain `xilo` unshadowed. The store path the _shipped_ form bakes in is `tests/shellwrap.nix`'s job: it
builds hm-xilo's own wrapper over a placeholder CLI and asserts the `__XILO_PROGRAM__` marker was
substituted, so a wrapper that execs a literal nothing can run fails the gate instead of a person's
first `xilo push`.

```mermaid
flowchart LR
  S["tests/support.nix<br/>lib, flake outputs, features, hosts, hostLib,<br/>hostsAt(dir), featuresAt(dir), pkgs (nixpkgs + pinMeta overlay),<br/>fs (modules/defaults/filesystems.nix), rawFeaturePkgs, ck, suite,<br/>fixtureHost(dir, features, overrides) and hmCfg(host, args)<br/>which route fixtures through lib/builders.nix,<br/>assertWarnStubs, failingAssertions"] --> L["tests/loader.nix"]
  S --> CA["tests/caches.nix<br/>bare module eval of modules/caches.nix"]
  S --> WA["tests/warnings.nix<br/>bare module eval of modules/warnings-gate.nix"]
  S --> PT["tests/ptrace.nix<br/>bare module eval of features/hm-brave/nixos.nix,<br/>boot.kernel.sysctl stubbed: the value is a default,<br/>not a force, so mkDefault and a plain assignment win"]
  S --> C["tests/configs.nix"]
  S --> H["tests/home.nix"]
  S --> O["tests/outputs.nix"]
  S --> F["tests/filesystems.nix"]
  S --> M["tests/mounts.nix"]
  S --> PI["tests/pins.nix"]
  S --> WR["tests/wrap.nix<br/>nixGL wrap around a derived package"]
  S --> AP["tests/appdir.nix<br/>fixture build, not an eval"]
  S --> BL["tests/brave-layout.nix<br/>fixture build over a synthetic rpm payload"]
  S --> YZ["tests/yazi-install.nix<br/>fixture build over the pinned yazi sources"]
  S --> SW["tests/shellwrap.nix<br/>fixture build of credsctl + sopsctl + xilo-wrapped, taken from<br/>the feature modules that ship them<br/>the build's exit status is the shellcheck, and the marker-substituted<br/>wrapper it produces is what tests/xilo.bats drives"]
  S --> DK["tests/disko.nix<br/>bare eval with disko's own module stubbed out"]
  S --> SU["tests/suite.nix<br/>nix-unit attrset merged from filesystems, pins, caches, disko,<br/>warnings, zram and loader, plus two tripwires that make an<br/>empty suite file impossible to pass vacuously"]
  SU --> L
  SU --> CA
  SU --> WA
  SU --> F
  SU --> PI
  SU --> DK
  FX["tests/fixtures/<dir>/hosts/*.nix<br/>shapes no real host uses"] --> L
```

Why two kinds of assertion: Nix errors are deferred values, so `builtins.tryEval` cannot catch
them. A check that must fail is a nix-unit attribute carrying `expectedError` (its `type` and `msg`
are what nix-unit compares against the thrown error), and its exit status is the assertion;
everything else is a boolean check inside a suite. Fixture directories exist so loader guards never
depend on a real host changing shape.

Each suite runs in its own process inside a transient systemd scope (`MemoryMax`, `MemoryHigh` at
90% of it, `MemorySwapMax` at half of it; RSS polled every 20ms — systemd only reports
`MemoryPeak` while the unit is alive, so a peak read after the scope exits is gone). Swap is
_capped_, not forbidden: with `MemorySwapMax=0` an allocation that cannot be met from free RAM
stalls instead of being killed, and the gate hung on this box.

Splitting is not cosmetic: forcing three host configs in one eval peaks at ~2.1GB, and a single
`nix flake check --no-build` needs ~2.6GB (measured), both over the 1792MB cap — hence
`configs.nix` runs one host per process. Going over the cap is a failure (exit 137), not a hang.
`run.sh` prints each eval's `peak=` on its line. Suites that share nothing but the store run in one
wave, throttled to 4 in flight, and the two bats tiers run at the same time — 23s of eval/build/config
work became 7s, and 54s of bats work became 22s. Measured today on this box: the whole gate ~31s,
**18 verdict lines** green — shell lint (11 files), the devShell tool check, one `nix-unit` run of 151
attributes, 4 eval suites, 4 fixture builds, 3 host configs, the mocked
rebuild, the stub bats tier (9 suites, 291 tests) as one parallel bats call, `terraform.bats`
(58 tests) inside `nix develop` **and inside a scope**, and parity. Widest peaks: `tests/home.nix`
981MB (the standalone profile, which forces its Home
Manager users plus the host's own home module and the raw `_package.nix` derivations it compares
wrapped output against), `terraform.bats` ~841MB at 16 jobs, host configs 666–751MB (propyl /
methyl-nixos / methyl), `wrap` 716MB
(derivation-text checks read drvAttrs, so no .drv is realized), `tests/suite.nix` 446MB for the whole
value tier where the same assertions split across six processes cost ~551MB measured earlier,
`outputs` 294MB, `mounts` 384MB, `brave-layout` 351MB, the devShell 343MB, the shellwrap fixture
243MB (nixpkgs' shellcheck is the work), the yazi-install fixture 205MB (two pinned sources
unpacked, nothing compiled), and the appdir fixture 82MB with no download. The stub bats suites print
no `peak=`: they run stubs in the open environment, a few seconds together,
and GNU `parallel` — which is what `bats --jobs` needs — is asserted by the devShell check above,
because a missing `parallel` makes `bats --jobs` run zero tests. Peaks move a few MB run to run.

## Build telemetry, outside the gate

`tests/build-harness.sh` measures one attribute — how much RAM it needs and how long it takes under
a cap — and is deliberately **not** part of `tests/run.sh`: the gate never runs a real build, and
this harness does. It wraps the attribute in the same transient scope `tests/nix-eval.sh` provides
and prints one telemetry line — `mode` (eval or build), `attr`, `cap`, `peak`, `swap`, `wall`,
`exit` — then the client's own output. Exit code is the client's.

- `peak`/`swap` are the scope's `MemoryPeak`/`MemorySwapPeak`, read while the unit is alive. That is
  the only authoritative number for a Nix eval (DESIGN.md, "Build RAM"): `NIX_SHOW_STATS` and
  `/usr/bin/time -v` both under-report it, so `--stats` is for thunk and attrset counts, never RAM.
- `wall` is the whole scoped run, so a run killed at the cap reports the time it took to die.
- `--build` realises instead, and reports `out=` plus the recursive NAR size (`nix path-info -Ssh`).
  Realisation runs in the root `nix-daemon`, outside the scope, so `peak` is the **client's** memory
  — eval — not the machine's total.
- It runs exactly what `features/hm-njust/nix.just` runs: `nix build --no-link --dry-run` for
  `njust eval`, `nix build --out-link` for `njust build`. Extra arguments after the attribute reach
  `nix build` verbatim.
- Rebuild telemetry (`nixos-rebuild`, `home-manager switch`) is `bootstrap.sh`'s own scope; wrap any
  other command with `tests/nix-eval.sh <cap> -- <cmd>`.
- Overrides: `BUILD_HARNESS_MEM` (cap, default 3072), `BUILD_HARNESS_LINK`.
- Two things that bite when measuring by hand: a file inside the flake that git has never tracked
  makes `nix build` fail, so `git add -N <file>` first; and an attribute expression is evaluated by
  the client, so to attribute a cost to one expression rather than a whole config, pass a scoped
  parenthesised expression — `-- '(.#nixosConfigurations.methyl.config.system.build.toplevel)'` —
  and `-- '.#<host>.config'` reports an eval peak only, never the toplevel's realisation.

Its own logic is gated without building anything: `tests/build-harness.bats` drives the harness
against a PATH stub and asserts the command mapping, the telemetry fields, and the refusals (~0MB).
Measuring every prospective host is four runs of one interface — **sequentially**, because two
scoped runs side by side contaminate each other's peak:

```bash
bash tests/build-harness.sh -- '.#nixosConfigurations.methyl.config.system.build.toplevel'
bash tests/build-harness.sh -- '.#nixosConfigurations.methyl-nixos.config.system.build.toplevel'
bash tests/build-harness.sh -- '.#nixosConfigurations.propyl.config.system.build.toplevel'
bash tests/build-harness.sh -- '.#homeConfigurations.josh@methyl-bazzite.activationPackage'
```

## What each suite covers

```mermaid
flowchart TD
  subgraph loader["loader.nix — pure, ~0.2s (50 attributes)"]
    L0["hasPkg contract: pname shape, name shape, a miss,<br/>and a hit that forces nothing after it"]
    L1["feature discovery: features/ dirs == discovered;<br/>hm-* have home.nix; nixos-* have nixos.nix;<br/>overlay-bearing set; resolveFeaturePaths maps each feature to its file;<br/>a symlinked feature dir is discovered"]
    L2["host discovery: names == hosts/; every listed feature resolves;<br/>standalone lists no nixos-*; NixOS hosts carry modules; hmUsernames;<br/>adminUsernames derives from isAdmin on enabled users;<br/>and host facts declare no machine label — the device name is terraform.sh's to settle"]
    L3["fixtures: flat record derives osUsernames/hmUsernames;<br/>directory host auto-discovers nixos.nix + home-*.nix;<br/>symlinked nixos.nix/home-*.nix are discovered;<br/>a declared homeModules.<user> keeps the discovered home-<user>.nix"]
    L4["hostLib: scalar last-wins, list union deduped by first occurrence,<br/>nested attrsets deep, derivation-shaped leaf wins,<br/>profiles merge, mergeHome forces the standalone shape"]
  end
  subgraph configs["configs.nix — forces every NixOS config, one host per process"]
    C1["per-host facts: hostName, timezone, user shell"]
    C2["universal wiring: tailscale, podman, firefox, printing, wheel"]
    C3["gating: gaming stack only on methyl; gnome/qemu/btrfs only on methyl-nixos;<br/>kait2en+fprintd only on propyl; korthos methyl-only; dms everywhere;<br/>absence read from namespace/systemd-unit/option, never by scanning the package list;<br/>the positive side of every absence signal is asserted too, so absence is not vacuous"]
    C4["cache gate: flakeCache.ready everywhere;<br/>substituters/keys counts == enabled caches;<br/>the caches each host's features actually require (nix-community, kait2en,<br/>wombatfromhell only where niri-spicy is on)"]
    C5["kernel: which kernel each host boots, incl. the kait2en kernel<br/>the feature pins rather than boot.kernelPackages"]
    C6["nixGL disabled: packages null for josh, which is what makes lib.nixGL.wrapGpu<br/>identity; the GUI features hand their pinned pname+version to the program options<br/>(identity by name, not outPath — forcing outPath pulls Brave's whole dependency<br/>closure, ~470MB per host); the PATH-once half lives in wrap/home,<br/>because counting home.packages forces every package name"]
    C7["drive parity (ADR-b77ec913151f, ADR-62773e12d275): recipe.owns == flakeHost.ownsWholeDisk;<br/>every mount the recipe names agrees on device and fsType; every other mount is a btrfs<br/>subvolume of the labelled root the recipe creates; no host declares a disko layout;<br/>systemd-boot with canTouchEfiVariables per host; /boot is vfat; /var/log neededForBoot;<br/>and the subvolume tree the generated hardware-configuration.nix declares is reproduced"]
    C8["nix.package is upstream Nix, not Lix (a Lix evaluator costs ~450MB more per host config);<br/>wl-watcher execs store paths only, and installs what its script calls"]
  end
  subgraph home["home.nix — forces the standalone HM config"]
    H1["builder facts: username, homeDirectory, genericLinux target;<br/>plus a fixture host asking for two features no real host lists (hm-dcal, hm-ghostty),<br/>each of which must reach PATH exactly once"]
    H2["features + packages the profile and the host contribute;<br/>hm-base ships packages, not program flags;<br/>expectations come from the host's own module and from what the config installs,<br/>so a host gaining or losing a feature stays green"]
    H3["nixGL wrapper names; packages set on this non-NixOS host;<br/>the host uses the default wrapper (mesa); every package from a feature derivation<br/>is wrapped (outPath differs from _package.nix's) and on PATH exactly once,<br/>with a companion check that at least one is installed so this cannot go vacuous"]
  end
  subgraph outputs["outputs.nix — reads the output attrsets"]
    O1["outputs are configurations, checks, apps and a devShell;<br/>cache-check and style are runnable apps whose scripts are read back"]
    O2["checks keyed by the system each config was built for"]
    O3["one check per configuration, and each is a derivation"]
    O4["configs derived from host records; host name wired into config.flakeHost"]
  end
  subgraph caches["caches.nix — bare module eval of modules/caches.nix (13 attributes)"]
    CA1["a required cache the host does not enable is warned by name,<br/>including the fix line; an enabled one warns nothing"]
    CA2["ready false while a required cache is disabled, true when enabled or when nothing is required"]
    CA3["a required cache outside the registry fails an assertion"]
    CA4["substituters and keys come from the enabled caches in order; [] means none"]
  end
  subgraph filesystems["filesystems.nix — pure lib (56 attributes)"]
    F1["mkMounts: entry keys win over defaults, entry `options` REPLACE the defaults,<br/>`extraOptions` APPEND them (and land after the subvol), subvol appended last,<br/>an empty option list is dropped, a redefined subvol is not duplicated"]
    F2["mountsFromRecipe: label -> /dev/disk/by-label/<label>, fs -> fsType,<br/>options -> comma string; a partition with no mount is created, not mounted;<br/>empty options are dropped; no partitions mounts nothing"]
    F3["mkUnitMounts: string shorthand, options joined to a comma string,<br/>`extraOptions` joined into the same string, skipIfMissing -> ConditionPathExists,<br/>sugar keys removed; the same trees drive the two mount suites"]
    F4["automount whitelist: only where/description/wantedBy/unitConfig/<br/>automountConfig, so mount->automount->mount is not an ordering cycle"]
    F5["unitName: where -> escaped unit name (dash and space escaped, an<br/>unnormalized path refused), so consumers name a unit the way mkUnitMounts does"]
    F6["joinUnitMounts: groups concatenate in order, [] == {}"]
  end
  subgraph mounts["mounts.nix — the hosts enabling nixos-automounts, taken from the records"]
    M1["only those hosts have systemd.automounts (from the host's automounts table, not a<br/>hardcoded name list); every automount has a<br/>mount at the same where (proves where -> unit-name derivation)"]
    M2["that mount requires and after <unit>.automount;<br/>automounts carry no requires/after/wants and no mountConfig;<br/>automounts are wanted by multi-user.target"]
    M3["mounts: mountConfig.TimeoutSec 5, ConditionPathExists shared with the<br/>automount; cifs options carry credentials=/etc/.smb-credentials"]
  end
  subgraph pins["pins.nix — pin metadata contract (7 attributes)"]
    PN1["metadata-backed features discovered; templates use only<br/>the tokens both expanders know ({repo} {version} {arch})"]
    PN2["every pin expands to a resolved url for every pinned system; arches boundaries are<br/>carried by pin-meta.pinSystemSystems, so no second coverage check here"]
    PN3["features/<name>/update.sh is absent or a symlink to lib/updater.sh<br/>the key is quoted — .update.sh would walk update then sh"]
  end
  subgraph disko["disko.nix — bare eval, disko's own module stubbed out (6 attributes)"]
    DK1["a gpt layout on a host whose flakeHost.ownsWholeDisk is false fails exactly one<br/>assertion, and the message names the fact that clears it; gpt with ownership passes;<br/>a btrfs layout needs no ownership; a host with no layout turns disko's enableConfig off,<br/>because disko writes fileSystems whenever it is on and would clobber fsLib's mounts"]
  end
  subgraph wrap["wrap.nix — nixGL around derived packages, peak ~716MB"]
    WR1["three fixture configs built by lib/builders.nix itself (support.fixtureHost + hmCfg,<br/>so a builder change breaks this suite): a NixOS side, a<br/>standalone side with the default wrapper, and a standalone side setting<br/>features.nixgl.wrapper = nvidiaPrime (hm-nixgl, hm-brave, hm-zed, hm-ghostty in all three).<br/>hm-nixgl sets packages only on the non-NixOS side; wrapGpu is identity there and returns<br/>a distinct derivation here, and delegates to Home Manager's own lib.nixGL.wrap; defaultWrapper<br/>follows the host's option (mesa on both default sides, nvidiaPrime when set) — the Nvidia<br/>wrapper itself cannot be forced here, because nixGL's Nvidia wrapper reads the host driver<br/>version and gets null. pname and version survive the wrap; programs.chromium's<br/>commandLineArgs branch fires on both sides and the overridden package keeps its<br/>pname/version, and wrapGpu stays identity on the overridden derivation on the NixOS side<br/>(the branch is an option value, so it is asserted as one rather than by forcing Home<br/>Manager's chromium override chain); each package reaches home.packages exactly once;<br/>brave's .drv wraps its bin entries only when commandLineArgs are set;<br/>the wrapped Ghostty still links the AppDir (`cp -rs`) and execs its launcher through<br/>nixGL's combined wrapper, so its /proc/self/exe AppDir resolution survives the wrap"]
  end
  subgraph appdir["appdir.nix — fixture build, peak ~86MB"]
    AD1["features/hm-ghostty/_package.nix's real installPhase against a synthetic AppDir built<br/>from one tree table (kept, relocated, dropped, left alone):<br/>bin/ghostty kept and executable, AppRun / sharun / dash / .env / .DirIcon and<br/>bin/*.hook dropped, desktop entry and icon moved into share/ not copied,<br/>the resource trees left alone, and upstream's /tmp/EKFs= rewrite confined to<br/>the four bundled paths that carry it (lib/libfontconfig.so.1.17.0, lib/libglycin_ng.so,<br/>lib/libgtk-4.so.1.2400.1, shared/bin/ghostty) — anything else carrying one fails"]
  end
  subgraph brave["brave-layout.nix — fixture build, peak ~350MB"]
    BR1["features/hm-brave/_package.nix's real installPhase over a synthetic rpm payload:<br/>the app lands under opt/, bin/ symlinks to it (Home Manager's programs.chromium reads<br/>programs.chromium.package, so a broken symlink is a browser that will not start), the two<br/>desktop entries move to share/ and lose the rpm's absolute Exec, the icon goes where the<br/>desktop search paths look, and the rpm's usr/ is gone. The payload's binaries are copies of<br/>a store ELF because patchelf refuses a text file — the one thing the fixture cannot fake"]
  end
  subgraph yazi["yazi-install.nix — fixture build, peak ~204MB"]
    YZ1["features/hm-yazi/_package.nix's real postInstall over the two pinned sources:<br/>buildPhase and installPhase replaced and every Rust input dropped, so nothing<br/>compiles and no crate is fetched — completion files land in share/ from the<br/>revision actually pinned, which is what a bump would break"]
  end
  subgraph shellwrap["shellwrap.nix — fixture build, peak ~242MB"]
    SW1["credsctl.sh, sopsctl.sh and xilo.sh wrapped exactly as the feature modules ship<br/>them — taken from the modules, not re-declared, so a module that ships something<br/>else fails here: writeShellApplication's checkPhase is the assertion, xilo's store<br/>path is a placeholder so nothing upstream is fetched, and the built output is grepped<br/>for the substituted marker. runtimeInputs are asserted too — jq for credsctl,<br/>sops/age/jq/ssh-to-age for sopsctl, and no askpass helper among them, since<br/>ssh-to-age never reads SSH_ASKPASS"]
  end
  subgraph warnings["warnings.nix — bare module eval (13 attributes)"]
    W1["modules/warnings-gate.nix: assertion true with no warnings,<br/>false with one, and its message carries every warning verbatim"]
  end
  subgraph zram["zram.nix — fixture host enabling nixos-zram (4 attributes)"]
    Z1["the zram setup unit is defined, the generator package is installed,<br/>the settings file lands in environment.etc, and the compression<br/>algorithm is zstd — no real host enables this feature today"]
  end
```

```mermaid
flowchart LR
  subgraph throw["suite.nix attributes that must throw — expectedError carries type and msg"]
    R1["unknown feature name"]
    R2["two host files resolving to one name"]
    R3["host file written as a module instead of a record<br/>(asserted on the option error text; lib/hosts.nix guidance is<br/>addErrorContext, which Nix prints but is not part of the message)"]
    R4["host file authoring a derived name"]
    R5["mergeHome handed a nixos-* feature"]
    R6["a home configuration has no NixOS system"]
    R7["mkMounts options is a string, not a list;<br/>mkMounts / mkUnitMounts extraOptions is a string, not a list"]
    R8["mkUnitMounts options is a string, not a list"]
    R9["mkMounts entry is a string, not an attrset"]
    R10["mkUnitMounts entry is not a set"]
    R11["skipIfMissing without what (ConditionPathExists needs the device)"]
    R15["mountsFromRecipe refuses a mount with no label, two partitions mounting<br/>the same path, and a mounted partition with no filesystem — all three name<br/>a device the drive would not have"]
    R12["two kernel-pinning features on one host<br/>(boot.kernelPackages would be defined twice)<br/>and the same collision when the host pins it in its own nixos.nix"]
    R13["features.nixgl.wrapper outside Home Manager's wrapper enum<br/>(the wrong driver set is a runtime failure, not an eval one)"]
    R14["suite tripwires: an empty suite file and a duplicated attribute<br/>name both fail, so a suite cannot pass by contributing nothing"]
  end
```

Coverage rule: assert on **namespaces and values**, not on `enable` flags. A feature's option
defaults are unreliable evidence — several features ship packages without turning a program
option on — so checks look for the service, the package, or the kernel parameter the feature
actually produces.

Warnings and host assertions are **build-time** signals, and forcing either one evaluates a
host's whole module config (~2.0GB here, measured 2067MB on methyl): `config.assertions` forces `config.warnings`, and
`lib.asserts.checkAssertWarn` throws on failed assertions while printing warnings. So
`modules/warnings-gate.nix` asserts `config.warnings == []` and the build tier (`nix build`,
`nix flake check`, `nixos-rebuild switch`) fails on any warning; no eval suite may force
`config.assertions` or `config.warnings` of a real host. The gate's own logic is covered on a
bare `lib.evalModules` (`tests/warnings.nix`), as is the house warning (`tests/caches.nix`).

A one-off attribution eval of `config.assertions` outside a suite is legitimate, and the answer it
gives is a number rather than a verdict: warnings and assertions are per-config, so it runs against
one host at a time, and an empty list only proves that host is clean. Two costs it separated this
session, both on methyl: forcing `system.build.toplevel` alone costs ~1.8GB and adds ~4.8GB of build,
and the toplevel contains every mount unit fsLib generates, so a bad mount option fails the build and
not only the suite — while `flake.checks` costs ~41MB, because each check is a pre-derived path that
never re-evaluates a host config.

## What we do not cover

```mermaid
flowchart TD
  N["not covered"] --> N1["anything a build would prove:<br/>derivation contents, hashes, runtime behavior.<br/>Checks are asserted with isDerivation only"]
  N --> N2["installability only real hardware proves: bootloader install, firmware boot order,<br/>kernel modules nixos-generate-config writes. hardware-configuration.nix IS imported<br/>and evaluated (configs.nix asserts its subvolume tree is reproduced), but the device<br/>names it carries are terraform.sh's to settle, not the config's"]
  N --> N3["isolated home feature modules: every HM module needs HM's own<br/>option namespace, so isolation needs option declarations that<br/>duplicate HM. Coverage comes from the real host config instead,<br/>which evaluates all home-bearing features together"]
  N --> N4["secrets: agenix needs age keys, so idPath identities are<br/>asserted structurally, not decrypted"]
  N --> N5["network cache availability: bootstrap.sh reads the registry;<br/>whether a cache answers is not a configuration value"]
  N --> N6["other architectures: every host is x86_64-linux,<br/>so pin-meta's per-system boundaries are not exercised"]
  N --> N7["assertion text: NixOS assertions are data on .config.assertions,<br/>they never throw at eval, so we assert the collected list"]
  N --> N8["warnings observed at eval: they go to the CLI, not into a derivation log.<br/>The build tier fails them via modules/warnings-gate.nix"]
  N --> N9["store layouts beyond the three proven: hm-ghostty's AppDir, hm-brave's rpm<br/>and hm-yazi's completion layout. tmux, zed, dmemcg, korthos and lsfg unpack real<br/>vendor assets whose fixture would have to download them"]
```

The eight `features/*/_package.nix` derivations are covered on their **input** side by
`tests/pins.nix` (pin metadata expands to a resolved URL for every pinned system) and by
`tests/run.sh` diffing the bash and Nix URL expanders byte-for-byte. What a derivation then does
with that asset is build-tier: `tests/appdir.nix` proves hm-ghostty's relocation by re-running its
installPhase over a synthetic AppDir, `tests/brave-layout.nix` proves hm-brave's rpm layout by
re-running its installPhase over a synthetic rpm payload, `tests/yazi-install.nix` proves hm-yazi's
completion, man and icon layout by re-running its postInstall over the sources actually pinned, and
the wrap is proven at eval by `tests/wrap.nix`. The other five (`hm-tmux`, `hm-zed`,
`nixos-dmemcg`, `nixos-korthos`, `nixos-lsfg`) unpack assets whose fixture would have to download
them, so they stay input-side only.

Deliberately skipped: per-feature coverage of all 41 modules. Feature modules are exercised
through the hosts that enable them — 37 of 41 are enabled by at least one host, so they evaluate
and their effects are asserted. Four have no host today: `nixos-zram` is commented out in
`hosts/methyl-base/base.nix` and is covered by a fixture host in `tests/zram.nix`; `hm-dcal` and
`hm-ghostty` are listed nowhere and are covered by fixture hosts in `tests/home.nix` and
`tests/wrap.nix`; `nixos-disko` is listed nowhere and is covered only by `tests/disko.nix`, whose
guard is read back on a stubbed disko module. A feature no host asks for is not a shipping contract.
If one of them becomes load-bearing, cover it by enabling it on a fixture host, not by isolating the
module.
Kernel choice is the exception:
`nixos-cachyos` and `nixos-kait2en` both write `boot.kernelPackages`, so listing both on one host
is an authoring error — `lib/features.nix` throws on it (`tests/loader.nix`'s
`testTwoKernelFeaturesThrow` and `testKernelFeatureAndHostPinCollide`) and
`tests/configs.nix` asserts which kernel each host boots.
