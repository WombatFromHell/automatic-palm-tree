# expect: expected a list but found a string
# `options` is a list; a string must throw rather than be joined into one option.
((import ../support.nix).fs.mkMounts {} {"/m" = {options = "noatime";};})."/m".options
