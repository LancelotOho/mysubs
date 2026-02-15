#!/bin/bash
# /volume1/Disk_4T/scripts/proxy_update

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# source /volume1/Disk_4T/py3.13_env/bin/activate

./suboverrider.sh -c config_webdav.yaml -v  
