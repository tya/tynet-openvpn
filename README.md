# tynet-openvpn

Self-hosted OpenVPN remote-access server for `tynet.us`. Bridges its tap
device into the node's `vlan40` link (see `tya/tynet-infra`'s
`roles/vlan-interfaces`) so connecting clients become real members of the
home network's `vpn` VLAN — not a routed look-alike subnet. Two-factor via
PAM + `libpam-google-authenticator`: a client certificate for TLS identity,
a TOTP code for the OpenVPN "password" field.

Deployed into the `tynet-infra` microk8s cluster by ArgoCD — see
`gitops/openvpn/` in that repo. This repo only holds the image
(`Dockerfile`, `entrypoint.sh`, `up.sh`) and its Helm chart
(`deploy/charts/tynet-openvpn`); there are no secrets here — the CA, server
cert, and each user's TOTP seed are all generated fresh in-cluster on first
run and persisted on a PVC, never committed.

## Image

`ubuntu:24.04` + `openvpn`, `easy-rsa`, `libpam-google-authenticator`.
`entrypoint.sh` bootstraps the PKI on first run (idempotent — skipped once
a CA already exists on the mounted volume), bridges the node's `vlan40`
link into `br-vpn`, renders `server.conf` from env vars, and execs
`openvpn`. `up.sh` is OpenVPN's `--up` hook: it joins the tap device to the
same bridge once OpenVPN creates it.

Built and pushed to `ghcr.io/tya/tynet-openvpn` on every `v*` tag (see
`.github/workflows/image.yml`), `linux/arm64` only (the cluster is all Pi
nodes).

## Client enrollment

Not part of this repo — it's an interactive, per-device runbook:

1. `kubectl exec` into the pod, `useradd <you>`, run `google-authenticator`,
   scan the QR code into an authenticator app.
2. Per device: `easyrsa gen-req <device> nopass && easyrsa sign-req client <device>`,
   then assemble a `.ovpn` profile (`ca.crt` + the client cert/key +
   `ta.key`, `remote vpn.tynet.us 1194 udp`, `auth-user-pass`).
3. Import into **OpenVPN Connect** (Mac App Store / iOS App Store).
