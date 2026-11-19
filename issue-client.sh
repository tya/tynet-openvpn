#!/bin/bash
# Issues a new client certificate signed by this server's CA (restored
# from Secret/PKI_SECRET_NAME) and prints a ready-to-import .ovpn profile
# to stdout. The server never needs to retain issued client certs itself
# -- TLS verification only checks the chain against ca.crt -- so this
# reconstructs a throwaway easy-rsa pki dir each time rather than keeping
# one around.
#
# Run via: kubectl exec -it deploy/tynet-openvpn -n openvpn -- \
#            issue-client.sh <device-name> > <device-name>.ovpn
set -euo pipefail

NAME="${1:?usage: issue-client.sh <device-name>}"
PKI_DIR="${PKI_DIR:-/etc/openvpn/pki}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# easyrsa's own "Notice"/progress chatter goes to stdout, not stderr --
# redirected to this script's stderr (1>&2) so it never contaminates the
# .ovpn profile below, which callers pipe straight from this script's
# stdout into a file. Found live: a first real enrollment produced a
# 139-line file where the actual `client` config didn't start until
# line 34 -- 33 lines of easy-rsa prose ahead of it, which OpenVPN
# Connect would not have parsed as a valid profile.
easyrsa --batch init-pki 1>&2
mkdir -p pki/private pki/issued pki/certs_by_serial pki/revoked/{certs_by_serial,private,reqs}
cp "$PKI_DIR/ca.crt" pki/ca.crt
cp "$PKI_DIR/ca.key" pki/private/ca.key
echo 01 > pki/serial
: > pki/index.txt
echo "unique_subject = no" > pki/index.txt.attr

easyrsa --batch gen-req "$NAME" nopass 1>&2
easyrsa --batch sign-req client "$NAME" 1>&2

cat <<EOF
client
dev tap
proto ${OPENVPN_PROTO:-udp}
remote ${OPENVPN_REMOTE_HOST:-vpn.tynet.us} ${OPENVPN_PORT:-1194}
remote-cert-tls server
auth-user-pass
verb 3

<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(openssl x509 -in "pki/issued/${NAME}.crt")
</cert>
<key>
$(cat "pki/private/${NAME}.key")
</key>
<tls-auth>
$(cat "$PKI_DIR/ta.key")
</tls-auth>
key-direction 1
EOF
