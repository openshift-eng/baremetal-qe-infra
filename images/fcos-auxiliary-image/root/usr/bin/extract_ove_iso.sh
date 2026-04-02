#!/bin/bash

KONFLUX_SNAPSHOT_ID="${1}"
OVE_ISO_NAME="${2}"

function cleanup(){
  echo "Cleaning OVE ISO container images"
  podman rmi "$(podman images "${KONFLUX_SNAPSHOT_ID}" -qa)" -f
}

trap cleanup EXIT

echo "Extracting OVE ISO from ${KONFLUX_SNAPSHOT_ID}"
id=$(podman create --platform=linux/amd64 --userns=keep-id "${KONFLUX_SNAPSHOT_ID}")

echo "Copying OVE ISO to /opt/html/${OVE_ISO_NAME}"
podman cp "$id:/agent-ove.x86_64.iso" "/opt/html/${OVE_ISO_NAME}"