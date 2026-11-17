#!/bin/bash
# Runs on every container start. PKI bootstrap is idempotent (skipped once
# /etc/openvpn/pki/ca.crt exists on the mounted PVC); the bridge setup and
# server.conf render always run, since they're cheap and need to reflect
# current env vars (set by the Helm chart's Deployment).
set -euo pipefail

PKI_DIR="${PKI_DIR:-/etc/openvpn/pki}"
EASYRSA_DIR="$(dirname "$PKI_DIR")"

if [ ! -f "$PKI_DIR/ca.crt" ]; then
  echo "No CA found at $PKI_DIR -- bootstrapping a new one (first run only)."
  cd "$EASYRSA_DIR"
  easyrsa --batch init-pki
  easyrsa --batch build-ca nopass
  easyrsa --batch gen-req server nopass
  easyrsa --batch sign-req server server
  easyrsa --batch gen-dh
  openvpn --genkey secret "$PKI_DIR/ta.key"
fi

# Bridge setup: enslave the tagged VLAN interface that tynet-infra's
# roles/vlan-interfaces already created on this node into a bridge.
# OpenVPN's own tap device joins the same bridge once it comes up (see
# up.sh). Idempotent -- safe to re-run on every pod (re)start.
if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
  ip link add "$BRIDGE_NAME" type bridge
fi
ip link set "$BRIDGE_NAME" up
ip link set "$BRIDGE_UPLINK" master "$BRIDGE_NAME"
ip link set "$BRIDGE_UPLINK" up

cat > /etc/openvpn/server.conf <<EOF
port ${OPENVPN_PORT}
proto ${OPENVPN_PROTO}
dev ${TAP_DEVICE}
dev-type tap

ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/issued/server.crt
key ${PKI_DIR}/private/server.key
dh ${PKI_DIR}/dh.pem
tls-auth ${PKI_DIR}/ta.key 0

# Ethernet-bridging mode: no server/ifconfig-pool directive here on
# purpose -- clients get a real DHCP lease from the vpn VLAN's own DHCP
# server (10.0.40.1), the same as any wired device there.
server-bridge
push "route ${PUSH_ROUTES}"

plugin /usr/lib/openvpn/openvpn-plugin-auth-pam.so openvpn
verify-client-cert require

script-security 2
up /usr/local/bin/up.sh

keepalive 10 60
persist-key
persist-tun
verb 3
EOF

exec openvpn --config /etc/openvpn/server.conf
