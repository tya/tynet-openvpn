#!/bin/bash
# Runs on every container start, on whichever node the scheduler picked --
# this pod carries no node affinity and no PVC, so nothing here can assume
# "I ran on this node before." PKI state lives in a Kubernetes Secret
# (cluster-wide, not node-local) instead of a hostpath PVC for exactly that
# reason. Bridge setup and server.conf render always run; the PKI
# restore-or-bootstrap step is idempotent on whether the Secret already
# exists.
set -euo pipefail

PKI_DIR="${PKI_DIR:-/etc/openvpn/pki}"
PKI_SECRET_NAME="${PKI_SECRET_NAME:-tynet-openvpn-pki}"
NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
PKI_KEYS="ca.crt ca.key server.crt server.key dh.pem ta.key"

mkdir -p "$PKI_DIR"

if kubectl get secret "$PKI_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Restoring PKI from Secret/$PKI_SECRET_NAME in $NAMESPACE"
  for key in $PKI_KEYS; do
    kubectl get secret "$PKI_SECRET_NAME" -n "$NAMESPACE" -o "jsonpath={.data.${key}}" \
      | base64 -d > "$PKI_DIR/$key"
  done
  chmod 600 "$PKI_DIR"/*.key "$PKI_DIR/ta.key"
else
  echo "No Secret/$PKI_SECRET_NAME found -- bootstrapping a new CA (first run only)."
  WORK=/tmp/easyrsa-init
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"
  easyrsa --batch init-pki
  easyrsa --batch build-ca nopass
  easyrsa --batch gen-req server nopass
  easyrsa --batch sign-req server server
  easyrsa --batch gen-dh
  openvpn --genkey secret "$PKI_DIR/ta.key"

  cp pki/ca.crt "$PKI_DIR/ca.crt"
  cp pki/private/ca.key "$PKI_DIR/ca.key"
  cp pki/issued/server.crt "$PKI_DIR/server.crt"
  cp pki/private/server.key "$PKI_DIR/server.key"
  cp pki/dh.pem "$PKI_DIR/dh.pem"
  chmod 600 "$PKI_DIR"/*.key "$PKI_DIR/ta.key"

  # shellcheck disable=SC2046 # word-splitting the --from-file list is intended
  kubectl create secret generic "$PKI_SECRET_NAME" -n "$NAMESPACE" \
    $(for key in $PKI_KEYS; do printf -- '--from-file=%s=%s ' "$key" "$PKI_DIR/$key"; done)

  rm -rf "$WORK"
fi

# Restore every previously-enrolled user's TOTP secret the same way, so an
# existing user keeps working after this pod reschedules to a different
# node -- not just the CA. A no-op the first time (no Secret yet; users
# enroll via `google-authenticator` + sync-user.sh, see the repo README).
USERS_SECRET_NAME="${USERS_SECRET_NAME:-tynet-openvpn-users}"
if kubectl get secret "$USERS_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Restoring enrolled users from Secret/$USERS_SECRET_NAME in $NAMESPACE"
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    mkdir -p "/etc/openvpn/users/${user}"
    kubectl get secret "$USERS_SECRET_NAME" -n "$NAMESPACE" -o "jsonpath={.data.${user}}" \
      | base64 -d > "/etc/openvpn/users/${user}/.google_authenticator"
  done < <(kubectl get secret "$USERS_SECRET_NAME" -n "$NAMESPACE" \
              -o jsonpath="{range \$k,\$v := .data}{\$k}{\"\\n\"}{end}")
fi

# Bridge setup: enslave the tagged VLAN interface that tynet-infra's
# roles/vlan-interfaces already created on this node into a bridge.
# OpenVPN's own tap device joins the same bridge once it comes up (see
# up.sh). Idempotent -- safe to re-run on every pod (re)start, on whichever
# of the three nodes it landed on this time.
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
cert ${PKI_DIR}/server.crt
key ${PKI_DIR}/server.key
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
