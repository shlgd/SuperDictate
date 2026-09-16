#!/bin/bash
# Private release identity lives outside the checkout and is never auto-regenerated.
set -euo pipefail
umask 077
STORE="${SUPERDICTATE_SIGNING_STORE:-$HOME/Library/Application Support/SuperDictateSigning}"
COMMAND="${1:-}"
fail() { printf 'SuperDictate signing: %s\n' "$*" >&2; exit 1; }

case "$COMMAND" in
init)
    [[ "$(openssl version)" == OpenSSL\ 3.* ]] || fail "Creating a publisher certificate requires OpenSSL 3 on the build machine."
    [[ ! -e "$STORE" ]] || fail "Signing store already exists; refusing to replace its identity."
    mkdir -p "$(dirname "$STORE")"
    STAGE="$(mktemp -d "$(dirname "$STORE")/.superdictate-signing.XXXXXX")"
    trap 'rm -r "$STAGE"' EXIT
    openssl rand -hex 32 > "$STAGE/password"
    openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
        -subj '/CN=SuperDictate Release Signing/' \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=codeSigning' \
        -keyout "$STAGE/private.pem" -out "$STAGE/certificate.pem"
    openssl pkcs12 -export -legacy -inkey "$STAGE/private.pem" \
        -in "$STAGE/certificate.pem" -out "$STAGE/identity.p12" \
        -passout "file:$STAGE/password"
    openssl x509 -in "$STAGE/certificate.pem" -outform DER -out "$STAGE/certificate.cer"
    openssl x509 -in "$STAGE/certificate.pem" -noout -fingerprint -sha1 \
        | sed 's/.*=//;s/://g' > "$STAGE/identity.sha1"
    rm "$STAGE/private.pem"
    chmod 600 "$STAGE"/*
    mv "$STAGE" "$STORE"
    trap - EXIT
    printf 'Release identity created at %s. Back up this entire private directory securely.\n' "$STORE"
    ;;
sign)
    APP="${2:-}"
    ENTITLEMENTS="${3:-}"
    [[ -d "$APP" && "$APP" == *.app ]] || fail "Expected an app bundle."
    [[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "com.local.superdictate" ]] \
        || fail "Unexpected bundle identifier."
    [[ -f "$STORE/identity.p12" && -f "$STORE/password" && -f "$STORE/identity.sha1" ]] \
        || fail "No release identity. Run scripts/release-signing.sh init once."
    mkdir "$STORE/.signing-lock" 2>/dev/null || fail "Signing is already running; inspect .signing-lock if a previous build crashed."
    trap 'rmdir "$STORE/.signing-lock"' EXIT
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-keychain.XXXXXX")"
    KEYCHAIN="$WORK/signing.keychain-db"
    PASSWORD="$(cat "$STORE/password")"
    SEARCH_LIST=()
    while IFS= read -r line; do
        line="${line#*\"}"
        line="${line%\"*}"
        [[ -z "$line" ]] || SEARCH_LIST+=("$line")
    done < <(security list-keychains -d user)
    cleanup() {
        security list-keychains -d user -s "${SEARCH_LIST[@]}" >/dev/null 2>&1 || true
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
        rm -r "$WORK"
        rmdir "$STORE/.signing-lock"
    }
    trap cleanup EXIT
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security list-keychains -d user -s "${SEARCH_LIST[@]}" "$KEYCHAIN"
    security import "$STORE/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
    ARGS=(--force --sign "$(cat "$STORE/identity.sha1")" --keychain "$KEYCHAIN" --timestamp=none --options runtime)
    [[ -z "$ENTITLEMENTS" ]] || ARGS+=(--entitlements "$ENTITLEMENTS")
    codesign "${ARGS[@]}" "$APP"
    codesign --verify --deep --strict "$APP"
    # Pin the certificate, not merely a freely reproducible bundle identifier.
    codesign --verify --strict -R="certificate leaf = H\"$(cat "$STORE/identity.sha1")\"" "$APP"
    ;;
*) fail "Usage: $0 init | sign App.app [entitlements.plist]" ;;
esac
