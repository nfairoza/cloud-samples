#!/usr/bin/env bash
#
# make-ca-bundle.sh - build a CA bundle containing the public roots plus your
# corporate CA certificates, so cloud CLIs work on both public endpoints and
# internal sites behind a TLS-intercepting proxy.
#
# The common failure this fixes: someone points SSL_CERT_FILE at an exported
# site chain. That file REPLACES the public root list instead of adding to it,
# so every public endpoint starts failing certificate verification.
#
# See corporate-tls.md for the full explanation.

set -euo pipefail

OUTPUT="$HOME/ca-certs/combined-ca-bundle.pem"
BASE=""
CORP_CERTS=()
VERIFY_HOSTS=()
SKIP_VERIFY=0

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Build a CA bundle: public roots + your corporate CA certificates.

Usage: ./make-ca-bundle.sh [options]

Options:
  -c, --corp-cert FILE   Corporate CA or chain to add (repeatable)
      --from-host HOST   Fetch the chain from an internal HTTPS host and add
                         its CA certificates (repeatable), e.g. intranet.corp.com
  -b, --base FILE        Public root bundle to start from. Default: autodetected
                         from certifi, then the usual system locations.
  -o, --output FILE      Where to write. Default: ~/ca-certs/combined-ca-bundle.pem
      --verify-host HOST Also verify the result against this host (repeatable)
      --no-verify        Skip post-build verification
  -h, --help             Show this help

Examples:
  # From a corporate root you already have
  ./make-ca-bundle.sh -c corp-root.pem

  # Pull the CA certs straight off an internal site
  ./make-ca-bundle.sh --from-host intranet.corp.com

  # Several CAs, custom destination, extra verification target
  ./make-ca-bundle.sh -c root.pem -c issuing.pem \
      -o /etc/ssl/certs/combined.pem --verify-host git.corp.com

Afterwards, point your tooling at the result:
  export AWS_CA_BUNDLE=<output>      # AWS
  export REQUESTS_CA_BUNDLE=<output> # Azure, OCI, python-requests
  export SSL_CERT_FILE=<output>      # curl, openssl
  export NODE_EXTRA_CA_CERTS=<output>
  gcloud config set core/custom_ca_certs_file <output>
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--corp-cert)   CORP_CERTS+=("${2:?--corp-cert needs a file}"); shift 2 ;;
        --from-host)      FROM_HOSTS+=("${2:?--from-host needs a hostname}"); shift 2 ;;
        -b|--base)        BASE="${2:?--base needs a file}"; shift 2 ;;
        -o|--output)      OUTPUT="${2:?--output needs a path}"; shift 2 ;;
        --verify-host)    VERIFY_HOSTS+=("${2:?--verify-host needs a hostname}"); shift 2 ;;
        --no-verify)      SKIP_VERIFY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                fail "Unknown option: $1 (try --help)" ;;
    esac
done
FROM_HOSTS=("${FROM_HOSTS[@]:-}")
# Drop the empty placeholder bash leaves behind for an unset array.
[[ ${#FROM_HOSTS[@]} -eq 1 && -z "${FROM_HOSTS[0]}" ]] && FROM_HOSTS=()

command -v openssl >/dev/null 2>&1 || fail "openssl is required but not installed."

# --- locate the public root bundle --------------------------------------

find_base() {
    # certifi is the most current list on any machine with Python.
    if command -v python3 >/dev/null 2>&1; then
        local c
        c=$(python3 -c 'import certifi; print(certifi.where())' 2>/dev/null) || true
        [[ -n "$c" && -f "$c" ]] && { echo "$c"; return; }
    fi
    local candidates=(
        /etc/ssl/certs/ca-certificates.crt          # Debian, Ubuntu
        /etc/pki/tls/certs/ca-bundle.crt            # RHEL, Fedora
        /etc/ssl/ca-bundle.pem                      # SLES
        /usr/local/etc/openssl/cert.pem             # macOS Homebrew
        /etc/ssl/cert.pem                           # macOS, Alpine
    )
    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { echo "$f"; return; }
    done
}

if [[ -z "$BASE" ]]; then
    BASE="$(find_base)"
    [[ -n "$BASE" ]] || fail "Could not find a public root bundle. Pass one with --base.
Get a current list with:  python3 -m pip install --user certifi"
    log "Public roots: $BASE"
else
    [[ -f "$BASE" ]] || fail "Base bundle not found: $BASE"
fi

base_count=$(grep -c "BEGIN CERTIFICATE" "$BASE" || true)
[[ "$base_count" -lt 50 ]] && warn "Base bundle has only $base_count certificates - that looks like a site chain, not a root store. Public endpoints may still fail."
log "Base bundle holds $base_count certificates"

# --- fetch chains from internal hosts -----------------------------------

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

for host in "${FROM_HOSTS[@]}"; do
    log "Fetching certificate chain from $host"
    out="$TMPDIR_WORK/$(echo "$host" | tr -c 'a-zA-Z0-9._-' '_').pem"
    if ! echo | openssl s_client -showcerts -connect "$host:443" \
            -servername "$host" 2>/dev/null \
          | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$out" \
       || [[ ! -s "$out" ]]; then
        fail "Could not retrieve a certificate chain from $host"
    fi
    CORP_CERTS+=("$out")
    VERIFY_HOSTS+=("$host")
done

[[ ${#CORP_CERTS[@]} -gt 0 ]] || fail "Nothing to add. Pass --corp-cert FILE or --from-host HOST."

# --- split, filter, dedupe ----------------------------------------------
#
# Keep only CA certificates. A fetched chain starts with the site's leaf
# certificate, which must not go into a trust store - trusting a leaf would
# mean trusting that one host unconditionally, and it buys nothing because
# the CA above it is what actually needs to be trusted.

is_ca() {
    openssl x509 -in "$1" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE"
}

mkdir -p "$TMPDIR_WORK/split"
added=0
skipped_leaf=0
skipped_dupe=0
: > "$TMPDIR_WORK/additions.pem"

# Fingerprints already present in the base bundle, so we never add a duplicate.
csplit -s -z -f "$TMPDIR_WORK/split/base_" -b '%04d.pem' "$BASE" \
    '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true

known=""
for f in "$TMPDIR_WORK"/split/base_*.pem; do
    [[ -f "$f" ]] || continue
    fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2) || continue
    known="$known $fp"
done

for src in "${CORP_CERTS[@]}"; do
    [[ -f "$src" ]] || fail "Certificate file not found: $src"
    tag=$(basename "$src" | tr -c 'a-zA-Z0-9._-' '_')
    csplit -s -z -f "$TMPDIR_WORK/split/${tag}_" -b '%04d.pem' "$src" \
        '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null \
        || fail "No certificates found in $src"

    for f in "$TMPDIR_WORK/split/${tag}_"*.pem; do
        [[ -f "$f" ]] || continue
        subject=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//') || continue

        if ! is_ca "$f"; then
            echo "    skip (not a CA): $subject"
            skipped_leaf=$((skipped_leaf + 1))
            continue
        fi

        fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
        if [[ "$known" == *"$fp"* ]]; then
            echo "    skip (already present): $subject"
            skipped_dupe=$((skipped_dupe + 1))
            continue
        fi

        echo "    add: $subject"
        {
            echo "# $subject"
            openssl x509 -in "$f" 2>/dev/null
        } >> "$TMPDIR_WORK/additions.pem"
        known="$known $fp"
        added=$((added + 1))
    done
done

if [[ "$added" -eq 0 ]]; then
    if [[ "$skipped_dupe" -gt 0 && "$skipped_leaf" -eq 0 ]]; then
        warn "No new CA certificates - all $skipped_dupe were already in the base bundle."
    elif [[ ${#FROM_HOSTS[@]} -gt 0 ]]; then
        warn "No CA certificates were added: the host sent only its leaf certificate."
        warn "Many servers don't transmit their issuing chain, so --from-host can't"
        warn "recover the CAs. Get the corporate root from your IT self-service portal"
        warn "(or export it from a browser) and pass it with --corp-cert instead."
    else
        warn "No new CA certificates were added - everything was a leaf or already present."
    fi
fi

# --- assemble ------------------------------------------------------------

mkdir -p "$(dirname "$OUTPUT")"
{
    echo "# Combined CA bundle - public roots plus corporate CAs"
    echo "# Base: $BASE ($base_count certificates)"
    echo "# Added: $added corporate CA certificate(s)"
    echo "# Rebuild with make-ca-bundle.sh when your corporate CA rotates."
    echo
    cat "$BASE"
    echo
    echo "# ---- corporate CAs ----"
    echo
    cat "$TMPDIR_WORK/additions.pem"
} > "$OUTPUT"

chmod 644 "$OUTPUT"
total=$(grep -c "BEGIN CERTIFICATE" "$OUTPUT")
log "Wrote $OUTPUT ($total certificates: $added added, $skipped_dupe duplicate, $skipped_leaf non-CA)"

# --- verify --------------------------------------------------------------

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
    echo
    log "Verifying the bundle against live endpoints"
    hosts=(
        sts.us-east-2.amazonaws.com
        login.microsoftonline.com
        oauth2.googleapis.com
        identity.us-ashburn-1.oci.oraclecloud.com
        "${VERIFY_HOSTS[@]}"
    )
    failures=0
    for h in "${hosts[@]}"; do
        [[ -n "$h" ]] || continue
        printf '    %-44s ' "$h"
        result=$(echo | openssl s_client -connect "$h:443" -servername "$h" \
                    -CAfile "$OUTPUT" 2>&1 | grep -m1 "Verify return code" || true)
        if [[ "$result" == *"code: 0"* ]]; then
            echo -e "${GREEN}ok${NC}"
        elif [[ -z "$result" ]]; then
            echo -e "${YELLOW}unreachable (skipped)${NC}"
        else
            echo -e "${RED}${result#*Verify return code: }${NC}"
            failures=$((failures + 1))
        fi
    done

    if [[ "$failures" -gt 0 ]]; then
        echo
        warn "$failures host(s) failed verification. Your corporate root may be missing -"
        warn "see corporate-tls.md, 'Diagnose it first'."
    fi
fi

cat <<EOF

Point your tooling at it:

  export AWS_CA_BUNDLE="$OUTPUT"
  export REQUESTS_CA_BUNDLE="$OUTPUT"
  export SSL_CERT_FILE="$OUTPUT"
  export NODE_EXTRA_CA_CERTS="$OUTPUT"
  gcloud config set core/custom_ca_certs_file "$OUTPUT"

Add those exports to ~/.bashrc to make them persist.

If the AWS CLI still fails, something is overriding you - AWS_CA_BUNDLE in the
environment beats ca_bundle in ~/.aws/config. Check for a stale value, and make
sure 'verify_ssl = false' is not left behind in ~/.aws/config.
EOF
