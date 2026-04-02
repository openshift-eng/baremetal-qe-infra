#!/bin/bash
set -euo pipefail

OVE_ISO_NAME="${1}"
SSH_PUBLIC_KEY="${2}"

[ -z "$OVE_ISO_NAME" ] && { echo "Error: OVE_ISO_NAME is not provided."; exit 1; }
[ -z "$SSH_PUBLIC_KEY" ] && { echo "Error: SSH_PUBLIC_KEY is not provided."; exit 1; }

AGENT_SERVICE_URL="https://raw.githubusercontent.com/openshift/installer/refs/heads/main/data/data/agent/systemd/units/agent-interactive-console.service"
TEMP_FILE="/tmp/agent-interactive-console.service"
AGENT_SERVICE_FILE="/opt/html/agent-interactive-console.service"
EXTRACTED_IGN="/tmp/extracted_${OVE_ISO_NAME%.*}.ign"
UPDATED_IGN="/tmp/updated_${OVE_ISO_NAME%.*}.ign"
OVE_ISO_PATH="/opt/html/$OVE_ISO_NAME"

echo "Downloading agent interactive service to a temporary location..."
curl -sSL "$AGENT_SERVICE_URL" -o "$TEMP_FILE" || { echo "Download failed"; exit 1; }
sed -i  -e 's|dev-fb0.device ||g' \
        -e 's|TTYPath=.*|TTYPath=/dev/ttyS0|' \
        -e '/.*chvt 15/d' \
        -e '/.*chvt 1/d' \
        -e '\|/dev/fb0|d' \
        "$TEMP_FILE"

if [ ! -f "$AGENT_SERVICE_FILE" ]; then
    echo "Agent Service file missing. Updating agent service first-time..."
    mv "$TEMP_FILE" "$AGENT_SERVICE_FILE"
else
    NEW_HASH=$(sha256sum "$TEMP_FILE" | awk '{print $1}')
    OLD_HASH=$(sha256sum "$AGENT_SERVICE_FILE" | awk '{print $1}')

    if [ "$NEW_HASH" != "$OLD_HASH" ]; then
       echo "Updates detected. Patching..."
       mv "$TEMP_FILE" "$AGENT_SERVICE_FILE"
    fi
fi

echo "Extracting ignition file from the OVE ISO..."
coreos-installer iso ignition show "$OVE_ISO_PATH" > "$EXTRACTED_IGN"

echo "Adding sshAuthorizedKeys in the ignition file..."
jq -r -c --arg public_key "$SSH_PUBLIC_KEY" '.passwd.users=[{"name":"core","sshAuthorizedKeys":$public_key}]' "$EXTRACTED_IGN" > "$EXTRACTED_IGN.tmp" && mv "$EXTRACTED_IGN.tmp" "$EXTRACTED_IGN"

echo "Replacing agent interactive service in the ignition file..."
jq -r -c --arg agent_service "$(cat $AGENT_SERVICE_FILE)" '(.systemd.units[] | select(.name == "agent-interactive-console.service") | .contents) = $agent_service' "$EXTRACTED_IGN" | tr -d "\n" > "$UPDATED_IGN"

coreos-installer iso ignition embed -i "$UPDATED_IGN" -f "$OVE_ISO_PATH"

echo "Done!"