#!/bin/bash
# One time, local-only self-signed code signing identity. No Apple account needed.
set -euo pipefail
identity_name="Boring Notch Octave Local"
if security find-identity -v -p codesigning | grep -Fq "\"$identity_name\""; then
  echo "Using existing identity: $identity_name"
  exit 0
fi
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
cat > "$temp_dir/cert.conf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = $identity_name
O = Local Development
C = US
[extensions]
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical,CA:TRUE
EOF
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -config "$temp_dir/cert.conf" -keyout "$temp_dir/key.pem" \
  -out "$temp_dir/cert.pem" >/dev/null 2>&1
password=$(openssl rand -hex 24)
openssl pkcs12 -export -legacy -inkey "$temp_dir/key.pem" -in "$temp_dir/cert.pem" \
  -out "$temp_dir/identity.p12" -passout "pass:$password" >/dev/null 2>&1
security import "$temp_dir/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$password" -T /usr/bin/codesign >/dev/null
security add-trusted-cert -d -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" \
  "$temp_dir/cert.pem" >/dev/null
security find-identity -v -p codesigning | grep -F "\"$identity_name\"" || {
  echo "Certificate imported but macOS does not yet trust it for code signing." >&2
  echo "Trust it in Keychain Access, then rerun this script." >&2
  exit 1
}
