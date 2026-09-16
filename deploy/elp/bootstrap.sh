#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (for example: sudo env PUBLIC_IP=... OWNER_EMAIL=... bash bootstrap.sh)." >&2
  exit 1
fi

PUBLIC_IP="${PUBLIC_IP:-}"
OWNER_EMAIL="${OWNER_EMAIL:-admin@elpgpt.com}"
INSTALL_DIR="${INSTALL_DIR:-/opt/elp-fonoster}"
REPO_URL="${REPO_URL:-https://github.com/dnawebai/fonoster.git}"
BRANCH="${BRANCH:-main}"

if [ -z "$PUBLIC_IP" ]; then
  echo "PUBLIC_IP is required." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git openssl python3 ufw docker.io
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-v2 || apt-get install -y docker-compose-plugin
fi
systemctl enable --now docker

if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch origin "$BRANCH"
  git -C "$INSTALL_DIR" checkout "$BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
cp -n .env.example .env
cp -n config/integrations.example.json config/integrations.json
mkdir -p config/keys
if [ ! -s config/keys/private.pem ]; then
  openssl genpkey -algorithm rsa -out config/keys/private.pem -pkeyopt rsa_keygen_bits:2048
  openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem
fi
chmod 600 config/keys/private.pem
chmod 644 config/keys/public.pem

ARI_SECRET="$(openssl rand -hex 24)"
SIP_PROXY_SECRET="$(openssl rand -hex 24)"
POSTGRES_SECRET="$(openssl rand -hex 24)"
OWNER_SECRET="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
INFLUX_SECRET="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
INFLUX_TOKEN="$(openssl rand -base64 48 | tr -d '\n' | tr '/+' '_-')"
CLOAK_KEY="$(openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-')"

python3 - "$PUBLIC_IP" "$OWNER_EMAIL" "$ARI_SECRET" "$SIP_PROXY_SECRET" "$POSTGRES_SECRET" "$OWNER_SECRET" "$INFLUX_SECRET" "$INFLUX_TOKEN" "$CLOAK_KEY" <<'PY'
from pathlib import Path
import sys

path = Path('.env')
text = path.read_text()
keys = {
    'ROUTR_EXTERNAL_ADDRS': sys.argv[1],
    'ASTERISK_SIPPROXY_HOST': sys.argv[1],
    'RTPENGINE_PUBLIC_IP': sys.argv[1],
    'APISERVER_OWNER_EMAIL': sys.argv[2],
    'APISERVER_ASTERISK_ARI_SECRET': sys.argv[3],
    'ASTERISK_ARI_SECRET': sys.argv[3],
    'ASTERISK_SIPPROXY_SECRET': sys.argv[4],
    'POSTGRES_PASSWORD': sys.argv[5],
    'APISERVER_OWNER_PASSWORD': sys.argv[6],
    'APISERVER_INFLUXDB_INIT_PASSWORD': sys.argv[7],
    'INFLUXDB_INIT_PASSWORD': sys.argv[7],
    'APISERVER_INFLUXDB_INIT_TOKEN': sys.argv[8],
    'INFLUXDB_INIT_TOKEN': sys.argv[8],
    'APISERVER_CLOAK_ENCRYPTION_KEY': 'k1.aesgcm256.' + sys.argv[9],
    'APISERVER_DATABASE_URL': f'postgresql://postgres:{sys.argv[5]}@postgres:5432/fonoster',
    'APISERVER_IDENTITY_DATABASE_URL': f'postgresql://postgres:{sys.argv[5]}@postgres:5432/fnidentity',
    'ROUTR_DATABASE_URL': f'postgresql://postgres:{sys.argv[5]}@postgres:5432/routr',
    'RTPENGINE_PORT_MIN': '10000',
    'RTPENGINE_PORT_MAX': '20000',
    'ASTERISK_RTP_PORT_START': '10000',
    'ASTERISK_RTP_PORT_END': '20000',
    'NODE_ENV': 'production',
}

lines = text.splitlines()
seen = set()
out = []
for line in lines:
    if '=' in line and not line.lstrip().startswith('#'):
        key = line.split('=', 1)[0]
        if key in keys:
            out.append(f'{key}={keys[key]}')
            seen.add(key)
            continue
    out.append(line)
for key, value in keys.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
PY

chmod 600 .env

# Host firewall. Keep the insecure/default Fonoster API port 8449 closed publicly.
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5060/udp
ufw allow 5060:5063/tcp
ufw allow 10000:20000/udp
ufw --force enable

# Pull first so failure happens before modifying live containers.
docker compose -f compose.yaml -f deploy/elp/compose.production.yaml pull
docker compose -f compose.yaml -f deploy/elp/compose.production.yaml up -d

echo
printf '%s\n' "Fonoster ELP stack started." \
  "Install directory: $INSTALL_DIR" \
  "Public IP: $PUBLIC_IP" \
  "API port 8449 remains blocked externally until TLS is configured." \
  "Next: configure DNS + TLS, create Fonoster API keys, then attach the dedicated SIP carrier/DID." \
  "PSTN readiness in ELP GPT must remain false until live inbound and outbound tests pass."
