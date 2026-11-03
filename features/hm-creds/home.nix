# 'hm-creds': credsctl, the helper over the record store in ~/.local/share/credentials.
# One file per secret; the extension picks the backend — .cred is decrypted by systemd-creds
# (silent, machine-bound), .sops.json by sops through sopsctl (portable, and the key is fetched by
# running SOPS_KEYS_CMD, so no terminal is involved). Records are immutable: encrypt never overwrites
# and writes 0400, so a change is remove + re-add. Machine-local secrets consumed by automation stay
# .cred.
#
# Opt-in through the host feature list (hosts/<host>/default.nix → "hm-creds"), like every other
# feature — the feature list is the gate, no enable flag. `credsctl` with no arguments prints the
# whole contract: commands, the change recipe, the backend rule, and the exit codes.
#
# systemd-creds comes from the host PATH (/usr/bin/systemd-creds on Bazzite, systemd's copy on
# NixOS). Everything else is a `runtimeInputs` entry, because writeShellApplication exports PATH
# from that list: credsctl runs jq and sopsctl, sopsctl runs sops, age (age-keygen, for `init`),
# ssh-to-age (for `init --from-ssh`) and jq. The passphrase of a protected ssh origin travels to
# ssh-to-age in that command's own environment: ssh-to-age is not ssh and never reads SSH_ASKPASS,
# so no askpass helper is shipped — a helper here could only be called by hand. `sops` is also
# installed plainly so a person can run `sops edit` on a record.
{pkgs, ...}: {
  home.packages = [
    pkgs.sops
    pkgs.age
    pkgs.ssh-to-age
    (pkgs.writeShellApplication {
      name = "credsctl";
      text = builtins.readFile ./credsctl.sh;
      runtimeInputs = [pkgs.jq];
    })
    (pkgs.writeShellApplication {
      name = "sopsctl";
      text = builtins.readFile ./sopsctl.sh;
      runtimeInputs = [pkgs.sops pkgs.age pkgs.jq pkgs.ssh-to-age];
    })
  ];
}
