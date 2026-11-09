---
id: ADR-8cd71b226ffb
type: adr
slug: a-recipe-names-filesystems-by-uuid-and-the-uuids
title: a recipe names filesystems by UUID, and the UUIDs are recorded, never assumed
created: 2026-11-09T01:51:15Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/filesystems.nix
  - terraform.sh
  - install.sh
  - tests/terraform.bats
  - tests/install.bats
constraint: |
  A recipe entry may declare `uuid`; when it does the derived mount device is `/dev/disk/by-uuid/<uuid>`, a terraform run records the UUIDs the drive actually carries into `<mount>/terraform.json`, and `deploy` refuses a recipe that mounts a partition declaring none.
enforced_by:
  - lib/filesystems.nix#mountsFromRecipe
  - terraform.sh#record_recipe
  - install.sh#deploy
amends: [ADR-62773e12d275]
ratified: 82249cb97b06
anchor: 9cad847f2320b98dded70659c3c113d8bb7e49f8
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-09T01:52:16Z
schema: 4
version: 2
---

A label is unique only inside one drive. Every host here declares the same two labels (`boot`,
`nixos`), so `/dev/disk/by-label/boot` answers whichever drive the kernel enumerated first — a
second install on the same machine, or a USB stick carrying the same label, answers the same name.
A filesystem UUID is unique by construction, so a recipe may declare one and the mount then names
one filesystem rather than one name.

`uuid` is optional, and `label` stays required when it is absent, so the recipe keeps working for a
drive whose filesystems have not been recorded yet. `mountsFromRecipe` takes `/dev/disk/by-uuid/<uuid>`
when the entry declares a uuid and `/dev/disk/by-label/<label>` otherwise, and the uuid is checked
against `[A-Za-z0-9][A-Za-z0-9-]*` at eval because it becomes one path component of the device: a
slash would escape `/dev/disk/by-uuid` and a space would split the device.

A uuid names a filesystem that **already exists**. `mkfs` is never told a uuid — not here, and not by
`--force` — so a recipe cannot pre-declare the uuid a fresh filesystem will invent. An entry that
declares a uuid on a partition this run would format refuses before any write, naming the file the
run would have recorded; an entry whose uuid no partition on the drive carries refuses the same way,
naming both uuids. `--verify` refuses a uuid the drive no longer carries, which is how a recipe
folded in and then reformatted gets caught rather than silently mounted somewhere else.

The recorded file is written by `terraform.sh --record`, after the reproduction and its checks came
back clean, and nothing is written before that: it re-reads the partition table, resolves every
entry, and writes the recipe whole to `<mount>/terraform.json` with `owns`, `disk`, sizes and options
preserved and `uuid` filled in per partition. A recipe that already declares every uuid has nothing
to record, so the stage writes no file. `--dry-run` writes none. With no recipe there is nothing to
record.

`/mnt` is writable and survives reboot, so `<mount>/terraform.json` becomes `/terraform.json` on the
installed host. It cannot live in the store: a flake evaluates purely, so reading mutable per-host
state needs `--impure` and `nix flake check` could no longer evaluate the host; a store path is
content-addressed and read-only, and the uuids exist only after the drive is formatted, so their hash
is not knowable at eval; an impure deploy-time override would build a closure the repo does not
describe, and the first `nixos-rebuild switch` after reboot would quietly revert the mounts to
labels.

Folding is the operator's commit, not a stage. `install.sh --stage terraform` records and prints
where the file sits; the fold is `cp <mount>/terraform.json hosts/<host>/terraform.json` plus
`nix flake check`, and no stage copies, renames or backs up a repo file, because the answer to a
prompt is never an edit to the flake. `install.sh --stage deploy` refuses before `nixos-install`
runs while the recipe mounts a partition that declares no uuid, repeating the same instruction, and
the gate is skipped for a host with no recipe file. Presence is the gate; correctness is
`--verify`'s job.

Amends `ADR-62773e12d275`, which stays binding: mounts still come from the recipe and are never
hand-written. Only the device's form changes when an entry declares a uuid.

Measured on file-backed filesystems: `mkfs.fat`'s uuid reads back as 8 hex with a dash (`BBD9-580F`),
`mkfs.btrfs`' as a UUID (`e7b0e010-10bf-4984-b941-5c7c182d1b74`), and `mkfs.xfs` refuses a regular
file, so the bats fixture cannot cover an xfs uuid at all.
