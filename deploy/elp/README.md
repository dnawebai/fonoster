# ELP GPT Fonoster production deployment

This directory contains the production bootstrap and configuration notes for the ELP GPT telephony control plane.

## Architecture

```text
PSTN
  |
Canadian DID / SIP carrier
  |
Fonoster (Routr + RTPEngine + Asterisk)
  |
Retell custom SIP number
  |
ELP GPT Assistant
```

Fonoster replaces Twilio as the programmable telephony/PBX layer. A real PSTN DID still requires an upstream SIP carrier. ELP currently targets a Canadian SIP carrier endpoint and keeps outbound calling fail-closed until the carrier, Fonoster routing objects, Retell custom-number binding, and live inbound/outbound tests all pass.

## Host requirements

Use a dedicated Linux x86_64 host with a public IPv4 address. Fonoster runs multiple stateful services, including Postgres, InfluxDB, NATS, Routr, RTPEngine and Asterisk. Do not deploy this stack on Vercel/serverless infrastructure.

Recommended starting point for ELP production: 4 vCPU / 8 GB RAM / 80 GB SSD or larger. Scale after observing concurrent-call CPU, RTP and database load.

Required inbound firewall paths:

- TCP 22 from trusted administration addresses only.
- TCP 80 during ACME/Let's Encrypt certificate issuance and renewal.
- TCP 443 for the secured Fonoster API after TLS is enabled.
- UDP 5060 for SIP only if the carrier uses UDP.
- TCP 5060-5063 only for SIP transports actually in use.
- UDP 10000-20000 for RTP media.

Restrict SIP signaling to the selected carrier/Retell IP ranges whenever practical. Do not expose Postgres, InfluxDB, NATS, Asterisk ARI or internal gRPC ports publicly.

## Bootstrap

On a fresh Ubuntu host:

```bash
sudo PUBLIC_IP=<server-public-ip> \
  OWNER_EMAIL=<admin-email> \
  bash deploy/elp/bootstrap.sh
```

The bootstrap script:

1. installs Docker and basic host dependencies;
2. prepares `/opt/elp-fonoster` from this repository;
3. generates RSA identity keys;
4. creates strong random service/database secrets;
5. configures the public SIP/RTP address;
6. starts the Fonoster Docker Compose stack;
7. leaves PSTN activation disabled until routing and live-call tests pass.

## TLS

Before exposing the Fonoster API publicly, point the chosen API hostname to the server and follow Fonoster's current Let's Encrypt procedure. The official self-host documentation expects the Envoy service to mount the certificate chain and serve the API on TCP 443.

Recommended hostnames:

- `fonoster-api.elpgpt.com` — Fonoster API
- `fonoster-sip.elpgpt.com` — SIP identity/FQDN where required

## SIP carrier

ELP should use a dedicated Canadian DID owned by the telephony carrier; Edgar's personal mobile number must not be used as the Fonoster DID.

For Telnyx-style credential authentication, create:

1. carrier SIP connection;
2. dedicated Canadian DID assigned to that connection;
3. Fonoster credential object when required;
4. Fonoster trunk with the carrier host/transport;
5. Fonoster Number using the exact E.164 DID and `trunkRef`;
6. Fonoster Domain with an outbound egress policy pointing to that Number.

Use the carrier's Canadian SIP endpoint when available and prefer TLS signaling plus SRTP media where both sides support it.

## Retell

Retell remains the AI voice-agent layer. Import the dedicated DID as a Retell custom phone number and bind the ELP GPT Assistant as both inbound and outbound agent. The Retell number must exactly match `FONOSTER_DID_E164` and `ELP_RETELL_FROM_NUMBER` in ELP GPT.

## Go-live gate

Keep these ELP GPT variables false until all tests pass:

```text
ELP_TELEPHONY_PROVIDER=fonoster
FONOSTER_PSTN_READY=false
ELP_CUSTOM_TELEPHONY_READY=false
```

Go live only after verifying:

- Fonoster API reachable over TLS;
- SIP carrier authentication/routing active;
- dedicated DID associated with Fonoster trunk;
- Fonoster Number and Domain references recorded in ELP GPT;
- Retell custom number is bound to the ELP agent;
- inbound call reaches ELP and has two-way audio;
- outbound call from ELP reaches an approved test destination and has two-way audio;
- caller ID shows only the dedicated ELP DID;
- Retell post-call webhook reaches ELP GPT;
- no personal mobile number is used as the telephony ingress/caller ID.
