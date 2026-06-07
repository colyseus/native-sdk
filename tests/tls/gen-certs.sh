#!/usr/bin/env bash
# Generate a self-signed CA + server certificate for the TLS (wss://) tests.
#
# Produces, in the output dir (default: this script's dir):
#   ca.pem          trusted test CA (give this to the client)
#   ca.key          test CA private key
#   server.key      server private key
#   server.pem      server cert signed by ca.pem (SAN: localhost, 127.0.0.1)
#   other-ca.pem    a second, UNRELATED CA — for the "wrong CA" negative test
#
# Certs are short-lived and regenerated on demand; they are gitignored.
set -euo pipefail

OUT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DAYS=3650
mkdir -p "$OUT_DIR"

san="subjectAltName=DNS:localhost,IP:127.0.0.1"

# Trusted CA
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout "$OUT_DIR/ca.key" -out "$OUT_DIR/ca.pem" \
  -subj "/CN=Colyseus Test CA" >/dev/null 2>&1

# Server key + CSR
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT_DIR/server.key" -out "$OUT_DIR/server.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1

# Sign server cert with the trusted CA, embedding the SAN.
openssl x509 -req -in "$OUT_DIR/server.csr" \
  -CA "$OUT_DIR/ca.pem" -CAkey "$OUT_DIR/ca.key" -CAcreateserial \
  -days "$DAYS" -out "$OUT_DIR/server.pem" \
  -extfile <(printf '%s\n' "$san") >/dev/null 2>&1

# A second, unrelated CA — trusted by nobody — for the negative test.
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout "$OUT_DIR/other-ca.key" -out "$OUT_DIR/other-ca.pem" \
  -subj "/CN=Colyseus Other CA" >/dev/null 2>&1

rm -f "$OUT_DIR/server.csr" "$OUT_DIR/ca.srl"
echo "[gen-certs] wrote certs to $OUT_DIR"
