FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openvpn \
        easy-rsa \
        libpam-google-authenticator \
        iproute2 \
        iptables \
    && rm -rf /var/lib/apt/lists/*

# PAM stack for openvpn's auth-pam plugin: the OpenVPN "password" field
# becomes the TOTP code, nothing else. No pam_unix chaining (no
# forward_pass) -- the client cert already proves identity over TLS, this
# PAM service exists purely to check the second factor.
RUN printf 'auth required pam_google_authenticator.so\naccount required pam_permit.so\n' \
    > /etc/pam.d/openvpn

# The easy-rsa package ships its script at /usr/share/easy-rsa/easyrsa,
# not on PATH.
RUN ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY up.sh /usr/local/bin/up.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/up.sh

ENV OPENVPN_PORT=1194 \
    OPENVPN_PROTO=udp \
    BRIDGE_NAME=br-vpn \
    BRIDGE_UPLINK=vlan40 \
    TAP_DEVICE=tap0 \
    PUSH_ROUTES="10.0.0.0 255.255.0.0" \
    PKI_DIR=/etc/openvpn/pki

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
