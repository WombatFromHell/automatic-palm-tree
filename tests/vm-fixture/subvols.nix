# The subvolume tree terraform.sh lays down (ADR-97fb20bfd175), as <mount path>: <subvolume>.
# The fixture config mounts from here and tests/vm-fixture.nix compares it against the
# `subvolume_tree` terraform.sh actually creates, so the two cannot drift apart.
{
  "/" = "@";
  "/home" = "@home";
  "/nix" = "@nix";
  # Boot logging reads /var/log before the root filesystem switch, so it mounts early.
  "/var/log" = "@log";
  "/var/cache" = "@cache";
  "/var/lib/swap" = "@swap";
  "/.snapshots" = "@snapshots";
}
