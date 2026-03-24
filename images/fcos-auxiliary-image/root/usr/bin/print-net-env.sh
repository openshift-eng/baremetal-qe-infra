#!/bin/bash
set -euo pipefail
# This script is used to fill the network environment variables
# For each network interface, the following environment variables will be set if
# the interface is configured with an IP address:
#   <interface>_IPADDR
#   <interface>_NETMASK
#   <interface>_IP6ADDR
#   <interface>_IP6PREFIX

# get all network interfaces, but ignore the loopback interface
# shellcheck disable=SC2010
interfaces=$(ls /sys/class/net | grep -v lo | tr '-' '_')

for interface in $interfaces; do
    # skip the interface if it has no IPv4 address
    if ! ip -o -4 addr show dev "$interface" | grep -q 'inet '; then
        continue
    fi
    echo "${interface}_IPADDR=$(ip -o -4 addr show dev "$interface" | awk '{print $4}' | cut -f1 -d'/')"
    echo "${interface}_NETMASK=$(ip -o -4 addr show dev "$interface" | awk '{print $4}' | cut -f2 -d'/')"
    echo "${interface}_IP6ADDR=$(ip -o -6 addr show dev "$interface" | grep "scope global" | awk '{print $4}' | cut -f1 -d '/')"
    echo "${interface}_IP6PREFIX=$(ip -o -6 addr show dev "$interface" | grep "scope global" | awk '{print $4}' | cut -f2 -d '/')"
done