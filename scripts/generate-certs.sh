#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../Sources/MockWebServer/Resources/Certificates"
WORK_DIR=$(mktemp -d)
PASSWORD="test"

mkdir -p "$CERT_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Generating localhost-valid certificate (10 year validity)..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK_DIR/localhost-valid-key.pem" \
    -out "$WORK_DIR/localhost-valid-cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

openssl pkcs12 -export \
    -out "$CERT_DIR/localhost-valid.p12" \
    -inkey "$WORK_DIR/localhost-valid-key.pem" \
    -in "$WORK_DIR/localhost-valid-cert.pem" \
    -password "pass:$PASSWORD" \
    -legacy

echo "==> Generating expired certificate..."
# Create a cert with notBefore/notAfter in the past
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK_DIR/expired-key.pem" \
    -out "$WORK_DIR/expired-cert.pem" \
    -nodes \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -not_before 20200101000000Z \
    -not_after 20200102000000Z

openssl pkcs12 -export \
    -out "$CERT_DIR/expired.p12" \
    -inkey "$WORK_DIR/expired-key.pem" \
    -in "$WORK_DIR/expired-cert.pem" \
    -password "pass:$PASSWORD" \
    -legacy

echo "==> Generating wrong-hostname certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK_DIR/wrong-hostname-key.pem" \
    -out "$WORK_DIR/wrong-hostname-cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=wrong.example.com" \
    -addext "subjectAltName=DNS:wrong.example.com"

openssl pkcs12 -export \
    -out "$CERT_DIR/wrong-hostname.p12" \
    -inkey "$WORK_DIR/wrong-hostname-key.pem" \
    -in "$WORK_DIR/wrong-hostname-cert.pem" \
    -password "pass:$PASSWORD" \
    -legacy

echo "==> Done. Certificates written to $CERT_DIR"
ls -la "$CERT_DIR"
