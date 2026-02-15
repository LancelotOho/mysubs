#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

./suboverrider.sh -c config.yaml -v  
