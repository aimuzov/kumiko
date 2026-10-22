#!/bin/sh
# Creates a self-signed code signing certificate in the login keychain for local builds.
#
# An ad hoc signature changes with every build, and macOS ties Accessibility and Input Monitoring
# to the signature, so each rebuild would ask for both again. Builds signed with one stable
# certificate keep them. scripts/bundle.sh picks this certificate up by its name.
#
# The certificate is good for nothing but signing kumiko on this machine; delete it in Keychain
# Access ("Kumiko Local Development") to undo.

set -eu

name="Kumiko Local Development"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
	echo "\"$name\" is already in the login keychain"
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $name

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# The system openssl (LibreSSL) writes a PKCS#12 file that `security import` reads; OpenSSL 3
# defaults to ciphers it does not.
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
	-config "$work/openssl.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

password=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
	-name "$name" -passout "pass:$password" -out "$work/identity.p12"

# -T lets codesign use the key without asking each time.
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign

echo "created \"$name\""
