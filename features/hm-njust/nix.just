# Nix deploy recipes, ported from ~/.config/fish/helpers/nix.fish, plus the
# cherry-picked recipes from the old /etc/Justfile (features/nixos-justnh, now
# removed). Its switch/rswitch/dswitch/dry are already covered here by os-switch,
# rebuild and os-build --dry-run, so only default/info/clean came over.
#
# Flags, accepted by every recipe and in any order: --dry-run = evaluate only,
# never build/copy/ssh; --plain = plain nix instead of nix-fast-build; --sudo =
# run the nix client as root; --switch/--boot/--test = activation action. A bare
# argument is the target (user@host for home recipes, host for system recipes) and
# may appear anywhere; omit it to use the local host, which for system recipes may
# not be a NixOS host at all -- `njust info` lists them and the build says so. Anything else is forwarded
# verbatim to the client, so `--option name value` works everywhere. ponytail:
# option values must be one token (a multi-word value gets split and the client
# rejects it loudly); `--with-xilo` from nix.fish is not ported.
#
# Reached through `njust`, a wrapper pinned to this file, so plain `just`
# still finds your project justfiles.

set shell := ["bash", "-uc"]

# Shared values: one source of truth for every recipe below. Paths use env_var
# rather than `~` because some recipes interpolate them inside quotes.
flake := env_var_or_default("FLAKE_ROOT", env_var("HOME") + "/.config/flakeroot")
njobs := `nproc | awk '{ j = int($1 * 0.75); print (j > 1 ? j : 1) }'`
# Only what this Nix (Determinate Systems 2.34.8) accepts, so neither client
# spits warnings. ponytail: eval-cache / or-as-identifier are fork-only here.
nix_opts := "--option show-trace true --option connect-timeout 5 --option extra-experimental-features 'nix-command flakes'"
nfb_opts := "--max-jobs " + njobs + " " + nix_opts

# Closure attribute roots, out-links, and the system profile, spelled once.
hm_root := flake + "#homeConfigurations."
os_root := flake + "#nixosConfigurations."
hm_attr := ".activationPackage"
os_attr := ".config.system.build.toplevel"
hm_link := "/tmp/hm-result"
os_link := "/tmp/nixos-result"
deploy_link := "/tmp/nixos-deploy-result"
sys_profile := "/nix/var/nix/profiles/system"

# The NAS lives in its own flake and pulls from its own Cachix cache; these two
# options are copied verbatim from nix.fish's nixos_deploy_nas.
nas_flake := env_var_or_default("NAS_ROOT", env_var("HOME") + "/Projects/nasty-config")
nas_cache := "--option extra-substituters https://nasty.cachix.org --option extra-trusted-public-keys nasty.cachix.org-1:s+X88yw6+asphCNphTId/RQZHfmDF4fQ0uyzEz5SxLc="

# Local defaults, so recipe signatures stay short enough for `just --list` to align.
me := `whoami` + "@" + `hostname`
hn := `hostname`

# `njust` with no recipe lists the recipes (old /etc/Justfile `default`).
default:
    just --justfile "{{ justfile() }}" --list

# Which configs this flake exposes (old /etc/Justfile `list`).
info:
    nh os info {{ flake }}

# Garbage collect / clean generations and gcroots with nh. A bare token is the
# scope (`user`, `all` or `profile`, default `all`); --sudo elevates; --ask confirms
# unless you dry-run; --dry-run prints actions without performing them; `-k 3 -K 6h`
# is applied unless you pass your own `-k`/`-K`.

# Clean generations and gcroots (nix.fish: nh_clean).
clean *args:
    #!/usr/bin/env bash
    set -uo pipefail
    arr=({{ args }})
    scope=all
    sudo=()
    flags=()
    dry=false
    ask=true
    keep=false
    for ((i = 0; i < ${#arr[@]}; i++)); do
        a="${arr[i]}"
        case "$a" in
        --sudo) sudo=(sudo -i) ;;
        --dry-run|--dry|-n) dry=true; flags+=("--dry") ;;
        --ask|-a) ask=true ;;
        --no-gc|--no-gcroots|--no-direnv|--optimise|--keep-one|--cross-filesystems|-q|-v|-x)
            flags+=("$a") ;;
        -k|--keep|-K|--keep-since|--max|-e|--elevation-strategy)
            flags+=("$a" "${arr[i + 1]:-}"); keep=true; i=$((i + 1)) ;;
        *) scope="$a" ;;
        esac
    done
    [[ "$keep" == false ]] && flags+=(-k 3 -K 6h)
    [[ "$dry" == true ]] && ask=false
    [[ "$ask" == true ]] && flags+=(--ask)
    echo "${sudo[*]} nh clean $scope ${flags[*]}"
    "${sudo[@]}" nh clean "$scope" "${flags[@]}"

# Soft / optimised clean shortcuts, composed on top of `clean`. Soft means
# generations only (`--no-gcroots --no-direnv`) and `-k 3`; the `c?u`/`c?a` pair adds
# `--optimise`. All four confirm with `--ask` unless you pass `--dry-run`.

# Clean this user's generations, keeping 3 (nix.fish: nhcu).
cu *args: (clean "user" "--no-gcroots" "--no-direnv" "-k" "3" args)

# Clean every profile's generations, keeping 3 (nix.fish: nhca).
ca *args: (clean "all" "--no-gcroots" "--no-direnv" "-k" "3" args)

# cu + optimise the store (nix.fish: nhcuo).
ccu *args: (clean "user" "-k" "3" "--optimise" "--keep-one" args)

ccuf *args: (clean "user" "-k" "3" "--optimise" args)

# ca + optimise the store (nix.fish: nhcao).
cca *args: (clean "all" "-k" "3" "--optimise" "--keep-one" args)

ccaf *args: (clean "all" "-k" "3" "--optimise" args)

# nix.fish: _nfb + nix_build + nix_eval + _nix_dry_run, merged so the option set
# and the eval call exist once. `--sudo` is stripped and prefix-wrapped.
# ponytail: nix-fast-build 1.4 has no --dry-run/-n, so fast evaluation goes
# through nix-eval-jobs, the evaluator it delegates to.

# Build a closure; --dry-run evaluates instead, --plain uses nix instead of nix-fast-build.
build attr out_link="nix-result" *args:
    #!/usr/bin/env bash
    set -uo pipefail
    args=()
    sudo=()
    dry=false
    plain=false
    for a in {{ args }}; do
        case "$a" in
        --sudo) sudo=(sudo -i) ;;
        --dry-run) dry=true ;;
        --plain) plain=true ;;
        *) args+=("$a") ;;
        esac
    done
    if [[ "$dry" == true ]]; then
        if [[ "$plain" == true ]]; then
            echo "Evaluating {{ attr }} with nix build --dry-run..."
            GC_INITIAL_HEAP_SIZE=2G "${sudo[@]}" nix build {{ nix_opts }} --no-link --dry-run {{ attr }} "${args[@]}"
        else
            echo "Evaluating {{ attr }} via nix-eval-jobs..."
            GC_INITIAL_HEAP_SIZE=2G "${sudo[@]}" nix-eval-jobs {{ nfb_opts }} --flake {{ attr }} "${args[@]}"
        fi
    elif [[ "$plain" == true ]]; then
        "${sudo[@]}" nix build {{ nix_opts }} {{ attr }} --out-link {{ out_link }} "${args[@]}"
    else
        "${sudo[@]}" nix-fast-build {{ nfb_opts }} --flake {{ attr }} --out-link {{ out_link }} "${args[@]}"
    fi

# Evaluate a flake attribute: fast by default, --plain for plain nix (nix.fish: nix_eval).
eval attr *args: (build attr "/tmp/nix-eval-result" "--dry-run" args)

# nix.fish: _nix_switch_bin + _nix_remote_deploy.

# Activate a built closure locally or over ssh. The action argument belongs to
# switch-to-configuration (system, needs root); home-manager's activate takes none
# and runs as the user. --dry-run returns here, before any ssh or nix copy.
_activate out_link action="switch" remote="" *args:
    #!/usr/bin/env bash
    set -uo pipefail
    for a in {{ args }}; do [[ "$a" == --dry-run ]] && exit 0; done
    link="{{ out_link }}-"
    closure=$(realpath -e "$link/result" "$link/toplevel" "$link" 2>/dev/null | head -n 1)
    bin=$(realpath -e "$closure/bin/switch-to-configuration" "$closure/bin/activate" "$closure/activate" 2>/dev/null | head -n 1)
    if [[ -z "$closure" || -z "$bin" ]]; then
        echo "Error: no closure or switch binary at $link" >&2
        exit 1
    fi
    echo "Activating $closure ({{ action }}){{ if remote != "" { " on " + remote } else { "" } }}..."
    if [[ -n "{{ remote }}" ]]; then
        nix copy --to "ssh://{{ remote }}" "$closure"
        ssh -t "{{ remote }}" "sudo nix-env --profile {{ sys_profile }} --set $closure && sudo $bin {{ action }}"
        echo "  Manual switch on target: ssh {{ remote }} sudo $closure/bin/switch-to-configuration switch"
    elif [[ "$bin" == */switch-to-configuration ]]; then
        sudo nix-env --profile {{ sys_profile }} --set "$closure"
        sudo "$bin" {{ action }}
    else
        # home-manager's activate parses only --driver-version, so no argument here:
        # bare = driver version 0, which updates the HM profile itself, as the user.
        "$bin"
    fi

# One table for every deploy recipe: target, attribute, out-link, action and ssh
# remote. Flags go to the nix client; --dry-run stops before activation. A flag's
# value(s) stay attached, so only a bare token that follows no flag is the target.
_deploy kind="hm" *args:
    #!/usr/bin/env bash
    set -uo pipefail
    arr=({{ args }})
    tgt=""
    flags=()
    act=""
    dry=false
    for ((i = 0; i < ${#arr[@]}; i++)); do
        a="${arr[i]}"
        case "$a" in
        --switch) act=switch ;;
        --boot) act=boot ;;
        --test) act=test ;;
        --activate) act=activate ;;
        --dry-run) dry=true; flags+=("$a") ;;
        --plain|--sudo) flags+=("$a") ;;
        --option|--override-input|--remote-ssh-option)
            flags+=("$a" "${arr[i + 1]:-}" "${arr[i + 2]:-}"); i=$((i + 2)) ;;
        --*)
            flags+=("$a")
            [[ "${arr[i + 1]:-}" != "" && "${arr[i + 1]:-}" != --* ]] && { flags+=("${arr[i + 1]}"); i=$((i + 1)); } ;;
        *) tgt="$a" ;;
        esac
    done
    remote=""
    case "{{ kind }}" in
    hm) attr="{{ hm_root }}${tgt:-{{ me }}}{{ hm_attr }}"; link="{{ hm_link }}"; action=activate ;;
    hm-build) attr="{{ hm_root }}${tgt:-{{ me }}}{{ hm_attr }}"; link="{{ hm_link }}"; action="" ;;
    os-switch) attr="{{ os_root }}${tgt:-{{ hn }}}{{ os_attr }}"; link="{{ os_link }}"; action=switch ;;
    os-build) attr="{{ os_root }}${tgt:-{{ hn }}}{{ os_attr }}"; link="{{ os_link }}"; action="" ;;
    os-deploy) attr="{{ os_root }}${tgt:-{{ hn }}}{{ os_attr }}"; link="{{ deploy_link }}"; action=boot; remote="deployer@${tgt:-{{ hn }}}" ;;
    os-deploy-nas) attr="{{ nas_flake }}#nixosConfigurations.nasty{{ os_attr }}"; link="{{ deploy_link }}"; action=boot; remote=homenas-deployer; flags=("${flags[@]}" {{ nas_cache }}) ;;
    rebuild) attr="{{ flake }}#${tgt:-{{ hn }}}"; link=""; action="" ;;
    *) echo "Error: unknown deploy kind '{{ kind }}'" >&2; exit 1 ;;
    esac
    # boot/switch/test are switch-to-configuration actions; they must not retarget
    # an hm activation, which takes no action.
    [[ -n "$act" && "$action" != activate ]] && action="$act"
    if [[ "{{ kind }}" == rebuild ]]; then
        [[ -n "$act" ]] && flags+=("$act")
        sudo nixos-rebuild --flake "$attr" {{ nix_opts }} "${flags[@]}"
        exit 0
    fi
    if ! just --justfile "{{ justfile() }}" build "$attr" "$link" "${flags[@]}"; then
        [[ "{{ kind }}" == os-* && -z "$tgt" ]] && echo "hint: default target '{{ hn }}' is not a nixosConfigurations host; \`njust info\` lists them, or pass one explicitly" >&2
        exit 1
    fi
    [[ -z "$action" ]] && exit 0
    [[ "$dry" == true ]] && { echo "would activate: $link via $action${remote:+ on $remote}"; exit 0; }
    # No `@` prefix: shebang recipes go to bash as one script, so just's per-line
    # prefixes are not processed here (`@just` would be a command named "@just").
    just --justfile "{{ justfile() }}" _activate "$link" "$action" "$remote" "${flags[@]}"

# Home-manager closure for a user@host, built then activated (nix.fish: hm_fswitch).
hm *args: (_deploy "hm" args)

# Home-manager closure, built only — nothing is activated.
hm-build *args: (_deploy "hm-build" args)

# Roll back the active home configuration (nix.fish: hmrb).
hm-rollback:
    home-manager switch --rollback --flake {{ flake }} {{ nix_opts }}

# Home-manager generations (nix.fish: hmls).
list-hm:
    home-manager generations

# NixOS generations (nix.fish: nhdls); needs root, takes a profile to list another.
list-os profile=sys_profile:
    #!/usr/bin/env bash
    set -uo pipefail
    [[ -e "{{ profile }}" ]] || { echo "{{ profile }}: no system profile on this host"; exit 0; }
    sudo nix-env --list-generations --profile "{{ profile }}"

# Generation specs are nix-env's: ids, `old`, `+2M`, `1y`. Destructive, so an
# empty spec is refused rather than deleting whatever `old` would match.

# Delete home-manager generations (nix.fish: hmrm).
rm-hm *args:
    #!/usr/bin/env bash
    set -uo pipefail
    arr=({{ args }})
    [[ ${#arr[@]} == 0 ]] && { echo "usage: njust rm-hm <id|old|+2M|1y>"; exit 1; }
    home-manager remove-generations "${arr[@]}"

# Delete NixOS generations (nix.fish: nhdrm); the system profile is root-owned.
rm-os profile=sys_profile *args:
    #!/usr/bin/env bash
    set -uo pipefail
    arr=({{ args }})
    [[ -e "{{ profile }}" ]] || { echo "{{ profile }}: no system profile on this host"; exit 0; }
    [[ ${#arr[@]} == 0 ]] && { echo "usage: njust rm-os <id|old|+2M|1y> [profile]"; exit 1; }
    sudo nix-env --profile "{{ profile }}" --delete-generations "${arr[@]}"

# NixOS closure for a host, built then switched locally (nix.fish: nixos_fswitch).
os-switch *args: (_deploy "os-switch" args)

# NixOS closure, built only — nothing is activated.
os-build *args: (_deploy "os-build" args)

# Build, copy to a remote host, and activate there (nix.fish: nixos_fdeploy).
os-deploy *args: (_deploy "os-deploy" args)

# The NAS cache pair is appended (same order as nix.fish), so it wins over a
# user-supplied --option extra-substituters.

# NAS deploy: nasty-config's flake + its Cachix cache via ssh alias homenas-deployer.
os-deploy-nas *args: (_deploy "os-deploy-nas" args)

# Plain nixos-rebuild, no nix-fast-build (nixos-justnh / drs); its flags pass through.
rebuild *args: (_deploy "rebuild" args)

# One runnable check for the closure/binary resolution above: it drives
# `_activate` itself, so it tests behaviour instead of re-spelling the candidates.
_check:
    #!/usr/bin/env bash
    set -uo pipefail
    d=$(mktemp -d)
    mkdir -p "$d-/toplevel/bin" "$d-home-/bin"
    printf '#!/bin/sh\necho "switched $1"\n' >"$d-/toplevel/bin/switch-to-configuration"
    # HM 26.05's activate script parses only --driver-version, so the driver must
    # hand it no action argument. The fake script enforces that contract.
    printf '#!/bin/sh\n[ $# -gt 0 ] && { echo "activate got args: $*" >&2; exit 1; }\necho homeactivated\n' >"$d-home-/bin/activate"
    chmod +x "$d-/toplevel/bin/switch-to-configuration" "$d-home-/bin/activate"
    j=(just --justfile "{{ justfile() }}")
    # Home activation must run as the user: no sudo, so no password prompt.
    [[ "$(${j[@]} _activate "$d-home" activate)" == *"homeactivated"* ]] || { echo "home activation needs no root"; exit 1; }
    # Action forwarding belongs to switch-to-configuration (needs root, so gates
    # never execute it) and must never reach hm's activate: assert the dispatch shape.
    grep -qF 'sudo "$bin"' "{{ justfile() }}" || { echo "system action not forwarded"; exit 1; }
    n=$(grep -c '^ *"\$bin"$' "{{ justfile() }}")
    [[ "$n" == 1 ]] || { echo "hm activate branch: expected 1 bare call, got $n"; exit 1; }
    # A missing closure must fail, not activate nothing.
    rc=0; ${j[@]} _activate "$d-absent" activate >/dev/null 2>&1 || rc=$?
    [[ "${rc:-0}" == 1 ]] || { echo "missing closure must exit 1"; exit 1; }
    # --dry-run must stop before ssh/copy, even when a remote target is set.
    out=$(${j[@]} _activate /tmp/njust-absent switch homenas-deployer --dry-run 2>&1); rc=$?
    [[ "$rc" == 0 && "$out" != *Activating* && "$out" != *ssh* ]] || { echo "--dry-run reached ssh: $out"; exit 1; }
    # Flags may come first: --dry-run must not be read as a target.
    out=$(${j[@]} _deploy os-deploy --dry-run nosuchhost 2>&1)
    [[ "$out" == *nosuchhost* && "$out" != *ssh://* ]] || { echo "flag-first deploy leaked: $out"; exit 1; }
    # Build-only kinds must never activate.
    out=$(${j[@]} _deploy os-build --dry-run nosuchhost 2>&1)
    [[ "$out" == *nosuchhost* && "$out" != *Activating* ]] || { echo "os-build activated: $out"; exit 1; }
    # A flag's value must not be read as a target.
    out=$(${j[@]} _deploy os-build nosuchhost --option gc-auto 1000 --dry-run 2>&1)
    [[ "$out" == *nixosConfigurations.nosuchhost* && "$out" != *configurations.gc-auto* ]] || { echo "option value became the target: $out"; exit 1; }
    rm -rf "$d" "$d-" "$d-home-"
    echo ok
