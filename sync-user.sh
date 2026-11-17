#!/bin/bash
# Pushes one user's enrolled TOTP secret into the cluster-wide
# Secret/USERS_SECRET_NAME, so it survives this pod rescheduling to a
# different node. Run this right after enrolling a user -- without it,
# their TOTP secret only exists in this pod's ephemeral filesystem and is
# gone the moment it reschedules.
#
# Enroll, then sync:
#   kubectl exec -it deploy/tynet-openvpn -n openvpn -- bash -c \
#     'mkdir -p /etc/openvpn/users/ty && google-authenticator -s /etc/openvpn/users/ty/.google_authenticator'
#   kubectl exec -it deploy/tynet-openvpn -n openvpn -- sync-user.sh ty
set -euo pipefail

NAME="${1:?usage: sync-user.sh <name>}"
NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
SECRET_NAME="${USERS_SECRET_NAME:-tynet-openvpn-users}"
FILE="/etc/openvpn/users/${NAME}/.google_authenticator"

if [ ! -f "$FILE" ]; then
  echo "No such file: $FILE -- enroll first with google-authenticator -s $FILE" >&2
  exit 1
fi

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" --type=merge \
    -p "{\"data\":{\"${NAME}\":\"$(base64 -w0 < "$FILE")\"}}"
else
  kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
    "--from-file=${NAME}=${FILE}"
fi

echo "Synced ${NAME} into Secret/${SECRET_NAME} -- safe to reschedule now."
