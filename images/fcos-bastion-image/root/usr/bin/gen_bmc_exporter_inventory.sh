#!/bin/bash

set -eEo pipefail

BASE_DIR="/var/opt/bmc_exporter"
ACTIVE_NODES_FILE="$BASE_DIR/active_nodes"
BMC_DATA_FILE="$BASE_DIR/bmc_data"
BMC_EXPORTER_TEMPLATE="$BASE_DIR/templates/config.yml.j2"
BMC_EXPORTER_CONFIG_FILE="$BASE_DIR/config.yml"

# Remove commented lines
csvgrep --invert-match -c1 -m '#' /etc/hosts_pool_inventory > $ACTIVE_NODES_FILE

# Extract relevant columns only
csvcut -x -c bmc_address,bmc_user,bmc_pass $ACTIVE_NODES_FILE > $BMC_DATA_FILE

# Convert to jinja usable json format
yq '{"items": .}' $BMC_DATA_FILE -p=csv -o=json > $BMC_DATA_FILE.json


jinja2 $BMC_EXPORTER_TEMPLATE $BMC_DATA_FILE.json > $BMC_EXPORTER_CONFIG_FILE --format=json
