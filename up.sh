#!/bin/bash
# OpenVPN's `up` script: runs once the tap device exists, with its name as
# $1. Joins it to the same bridge entrypoint.sh already put the vlan40
# uplink on, so VPN clients become real members of that bridge (and so of
# VLAN 40) rather than a routed look-alike subnet.
set -euo pipefail

ip link set "$1" master "${BRIDGE_NAME:-br-vpn}"
ip link set "$1" up
