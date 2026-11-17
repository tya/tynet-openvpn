FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openvpn \
        easy-rsa \
        libpam-google-authenticator \
        iproute2 \
        iptables \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# PAM stack for openvpn's auth-pam plugin: the OpenVPN "password" field
# becomes the TOTP code, nothing else. No pam_unix chaining (no
# forward_pass) -- the client cert already proves identity over TLS, this
# PAM service exists purely to check the second factor.
#
# secret=...${USER}... + no_strict_owner: deliberately NOT using real Unix
# accounts for VPN users (useradd'd accounts would live only in this
# container's ephemeral filesystem and vanish on reschedule, same problem
# a PVC would have). pam_google_authenticator substitutes ${USER} with the
# OpenVPN username directly, no getpwnam() lookup involved, so a per-user
# secret file at a fixed path is enough -- no_strict_owner skips the
# ownership check that normally assumes a real account owns the file.
RUN printf 'auth required pam_google_authenticator.so secret=/etc/openvpn/users/${USER}/.google_authenticator no_strict_owner\naccount required pam_permit.so\n' \
    > /etc/pam.d/openvpn

# The easy-rsa package ships its script at /usr/share/easy-rsa/easyrsa,
# not on PATH.
RUN ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa

# kubectl, pinned to the cluster's own version -- the entrypoint uses it
# (via the pod's own ServiceAccount token, auto-detected in-cluster, no
# kubeconfig needed) to restore the CA/server PKI and each user's TOTP
# state from Kubernetes Secrets rather than a node-local PVC. That's what
# makes this pod reschedulable across nodes: Secrets live in etcd, not on
# whichever node happened to run it first.
ARG KUBECTL_VERSION=v1.32.13
ARG KUBECTL_SHA256=b1f87f196633a89208546d79bfa4e2470bda70e7bf42c4d3adb008ec208da9d1
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/arm64/kubectl" \
    && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY up.sh /usr/local/bin/up.sh
COPY issue-client.sh /usr/local/bin/issue-client.sh
COPY sync-user.sh /usr/local/bin/sync-user.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/up.sh \
    /usr/local/bin/issue-client.sh /usr/local/bin/sync-user.sh

ENV OPENVPN_PORT=1194 \
    OPENVPN_PROTO=udp \
    BRIDGE_NAME=br-vpn \
    BRIDGE_UPLINK=vlan40 \
    TAP_DEVICE=tap0 \
    PUSH_ROUTES="10.0.0.0 255.255.0.0" \
    PKI_DIR=/etc/openvpn/pki \
    PKI_SECRET_NAME=tynet-openvpn-pki \
    USERS_SECRET_NAME=tynet-openvpn-users \
    OPENVPN_REMOTE_HOST=vpn.tynet.us

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
