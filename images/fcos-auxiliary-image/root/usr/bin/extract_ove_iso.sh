#!/bin/bash

KONFLUX_SNAPSHOT_ID="${1}"
OVE_ISO_NAME="${2}"

id=$(podman create "${KONFLUX_SNAPSHOT_ID}")
podman cp "$id:/agent-ove.x86_64.iso" "/opt/html/${OVE_ISO_NAME}"

podman rmi "$id"