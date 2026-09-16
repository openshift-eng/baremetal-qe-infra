#!/bin/bash
set -euo pipefail

OVE_ISO_NAME="${1:-}"
PULL_SECRET="${2:-}"
INSTALL_CONFIG="${3:-}"
AGENT_CONFIG="${4:-}"

[ -z "$OVE_ISO_NAME" ] && { echo "Error: OVE_ISO_NAME is not provided."; exit 1; }
[ -z "$PULL_SECRET" ] && { echo "Error: PULL_SECRET is not provided."; exit 1; }
[ -z "$INSTALL_CONFIG" ] && { echo "Error: INSTALL_CONFIG is not provided."; exit 1; }
[ -z "$AGENT_CONFIG" ] && { echo "Error: AGENT_CONFIG is not provided."; exit 1; }

WORKING_DIR="/tmp/$OVE_ISO_NAME"
PULL_SECRET_PATH="/tmp/pull-secret"

mkdir -p "$WORKING_DIR"

echo "$INSTALL_CONFIG" > "$WORKING_DIR/install-config.yaml"
echo "$AGENT_CONFIG" > "$WORKING_DIR/agent-config.yaml"

if [ ! -f "$PULL_SECRET_PATH" ]; then
    echo "$PULL_SECRET" > "$PULL_SECRET_PATH"
fi

OVE_ISO_PATH="/var/mnt/data-storage/html/$OVE_ISO_NAME"

echo "Extracting OCP version from the OVE ISO..."
OCP_VERSION=$(coreos-installer iso ignition show "$OVE_ISO_PATH" |
        jq -r '.storage.files[] | select(.path == "/etc/assisted/manifests/cluster-image-set.yaml") | .contents.source' |
        cut -d',' -f2 |
        base64 -d |
        yq -r '.spec.releaseImage'
)

echo "Extracting openshift-install binary..."
oc adm release extract \
    --command=openshift-install \
    --to="$WORKING_DIR" \
    "$OCP_VERSION" \
    -a "$PULL_SECRET_PATH"

echo "Generating cluster manifests..."
"$WORKING_DIR/openshift-install" agent create cluster-manifests \
    --dir "$WORKING_DIR"

rm -f "$WORKING_DIR"/.openshift*

echo "Generating unconfigured ignition file..."
"$WORKING_DIR/openshift-install" agent create unconfigured-ignition \
    --dir "$WORKING_DIR"

echo "Replacing ignition file..."
coreos-installer iso ignition embed \
    -i "$WORKING_DIR/unconfigured-agent.ign" \
    -f "$OVE_ISO_PATH"

rm -rf "$WORKING_DIR"
echo "Done!"