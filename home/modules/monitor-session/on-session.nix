{pkgs, ...}: let
  onSessionScript = pkgs.writeShellScriptBin "on-session" ''
    #!${pkgs.bash}/bin/bash

    RUN_DIR="$HOME/.local/bin/monitor-session"
    mkdir -p "$RUN_DIR"

    if [[ "$1" == "false" ]]; then
    	# Find all executable *.sh files in the directory
    	scripts=("$RUN_DIR"/*.sh)

    	# Check if there are any matching scripts
    	if [[ -e "''${scripts[0]}" ]]; then
    		for script in "$RUN_DIR"/*.sh; do
    			if [[ -x "$script" && -r "$script" ]]; then
    				echo "Executing: $script"
    				"$script"
    				sleep 1
    			else
    				echo "Skipping non-executable script: $script"
    			fi
    		done
    	else
    		echo "No executable *.sh scripts found in $RUN_DIR. Skipping execution."
    	fi
    fi

  '';
in {
  inherit onSessionScript;
}
