#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PIN_SOURCE="$SCRIPT_DIR/../Sources/Services/PinnedSessionDelegate.swift"
PIN_HOST="${1:-lpm.dev}"
PIN_PORT="${2:-443}"

if ! command -v openssl >/dev/null 2>&1; then
	echo "TLS pin audit requires openssl." >&2
	exit 1
fi

if [ ! -f "$PIN_SOURCE" ]; then
	echo "PinnedSessionDelegate.swift was not found at $PIN_SOURCE." >&2
	exit 1
fi

AUDIT_DIR="$(mktemp -d)"
trap 'rm -rf -- "$AUDIT_DIR"' EXIT
CHAIN_FILE="$AUDIT_DIR/chain.pem"

if ! openssl s_client \
	-showcerts \
	-connect "$PIN_HOST:$PIN_PORT" \
	-servername "$PIN_HOST" \
	</dev/null >"$CHAIN_FILE" 2>"$AUDIT_DIR/openssl-error.log"; then
	echo "Could not load the TLS chain for $PIN_HOST:$PIN_PORT." >&2
	cat "$AUDIT_DIR/openssl-error.log" >&2
	exit 1
fi

awk -v target="$AUDIT_DIR" '
	/-----BEGIN CERTIFICATE-----/ { certificate += 1 }
	certificate > 0 { print > (target "/certificate-" certificate ".pem") }
' "$CHAIN_FILE"

matched=0
certificate_count=0
for certificate in "$AUDIT_DIR"/certificate-*.pem; do
	[ -f "$certificate" ] || continue
	certificate_count=$((certificate_count + 1))
	subject="$(openssl x509 -in "$certificate" -noout -subject)"
	pin="$(
		openssl x509 -in "$certificate" -pubkey -noout \
			| openssl pkey -pubin -outform DER 2>/dev/null \
			| openssl dgst -sha256 -binary \
			| openssl base64 -A
	)"
	if grep -Fq "\"$pin\"" "$PIN_SOURCE"; then
		status="MATCH"
		matched=1
	else
		status="not configured"
	fi
	printf '%s: sha256/%s (%s)\n' "$subject" "$pin" "$status"
done

if [ "$certificate_count" -eq 0 ]; then
	echo "The server did not return a certificate chain." >&2
	exit 1
fi

if [ "$matched" -ne 1 ]; then
	echo "TLS pin audit failed: no live chain pin exists in PinnedSessionDelegate.swift." >&2
	exit 1
fi

echo "TLS pin audit passed for $PIN_HOST:$PIN_PORT."
