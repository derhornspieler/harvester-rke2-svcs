#!/usr/bin/env bash
set -euo pipefail

# generate-ca.sh — Root CA, intermediate CA, and leaf certificate generation
#
# Usage:
#   ./generate-ca.sh root          [-o ORG] [-d DIR] [-r DAYS] [-f]
#   ./generate-ca.sh intermediate  [-o ORG] [-d DIR] [-i DAYS] [-n NAME]
#                                  --root-cert PATH --root-key PATH [-f]
#   ./generate-ca.sh leaf          [-o ORG] [-d DIR] [-l DAYS] [-n NAME]
#                                  --ca-cert PATH --ca-key PATH
#                                  --san DNS:x,DNS:y,IP:z [-k ecdsa|rsa] [-f]
#   ./generate-ca.sh verify        CHAIN_FILE
#
# Commands:
#   root          Generate a self-signed Root CA (default: 30yr, 4096-bit RSA)
#   intermediate  Generate an intermediate CA signed by an existing Root CA
#   leaf          Generate a leaf certificate signed by a CA (intermediate or root)
#   verify        Verify a certificate chain file
#
# Options:
#   -o ORG        Organization name (default: "My Organization")
#   -d DIR        Output directory (default: current directory)
#   -r DAYS       Root CA validity in days (default: 10950 = ~30 years)
#   -i DAYS       Intermediate CA validity in days (default: 5475 = ~15 years)
#   -l DAYS       Leaf certificate validity in days (default: 365 = ~1 year)
#   -n NAME       Name slug (e.g. "k3k-signing" or "airgap-proxy")
#   -k KEY_TYPE   Key type for leaf: "ecdsa" (P-256) or "rsa" (4096-bit) (default: ecdsa)
#   --root-cert   Path to existing root CA certificate (for intermediate cmd)
#   --root-key    Path to existing root CA private key (for intermediate cmd)
#   --ca-cert     Path to signing CA certificate (for leaf cmd)
#   --ca-key      Path to signing CA private key (for leaf cmd)
#   --san         Subject Alternative Names (comma-separated: DNS:x,DNS:y,IP:z)
#   -f            Force overwrite existing files

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

# Default values
ORG="My Organization"
OUTPUT_DIR="."
ROOT_DAYS=10950
INTERMEDIATE_DAYS=5475
LEAF_DAYS=365
NAME=""
ROOT_CERT=""
ROOT_KEY=""
CA_CERT=""
CA_KEY=""
SAN=""
KEY_TYPE="ecdsa"
FORCE=false

# Parse command
COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
    usage
fi
shift

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)          ORG="$2";              shift 2 ;;
        -d)          OUTPUT_DIR="$2";        shift 2 ;;
        -r)          ROOT_DAYS="$2";         shift 2 ;;
        -i)          INTERMEDIATE_DAYS="$2"; shift 2 ;;
        -l)          LEAF_DAYS="$2";         shift 2 ;;
        -n)          NAME="$2";              shift 2 ;;
        -k)          KEY_TYPE="$2";          shift 2 ;;
        --root-cert) ROOT_CERT="$2";         shift 2 ;;
        --root-key)  ROOT_KEY="$2";          shift 2 ;;
        --ca-cert)   CA_CERT="$2";           shift 2 ;;
        --ca-key)    CA_KEY="$2";            shift 2 ;;
        --san)       SAN="$2";              shift 2 ;;
        -f)          FORCE=true;             shift ;;
        -h|--help)   usage ;;
        *)
            # For verify command, positional arg is the chain file
            if [[ "$COMMAND" == "verify" ]]; then
                ROOT_CERT="$1"
                shift
            else
                err "Unknown option: $1"
                usage
            fi
            ;;
    esac
done

check_file_exists() {
    local path="$1"
    if [[ -f "$path" && "$FORCE" != true ]]; then
        err "File already exists: $path (use -f to overwrite)"
        exit 1
    fi
}

# =============================================================================
# Command: root
# =============================================================================
cmd_root() {
    local cert_path="${OUTPUT_DIR}/root-ca.pem"
    local key_path="${OUTPUT_DIR}/root-ca-key.pem"

    mkdir -p "$OUTPUT_DIR"
    check_file_exists "$cert_path"
    check_file_exists "$key_path"

    local cn="${ORG} Root CA"
    log "Generating Root CA: CN=${cn}"
    log "Validity: ${ROOT_DAYS} days (~$((ROOT_DAYS / 365)) years)"
    log "Output: ${OUTPUT_DIR}/"

    # Generate RSA 4096-bit key
    openssl genrsa -out "$key_path" 4096 2>/dev/null
    chmod 600 "$key_path"

    # Optional x509 nameConstraints via NAME_CONSTRAINT_DNS env var.
    # Supports comma-separated domains (e.g. "tiger.net,otherdomain.com").
    # A constraint of "tiger.net" permits all subdomains (vault.tiger.net, etc.).
    # If unset, no name constraints are applied — domain restrictions are enforced
    # at the Vault PKI role level (allowed_domains) instead.
    local dns_domains="${NAME_CONSTRAINT_DNS:-}"

    local nc_block=""
    if [[ -n "$dns_domains" ]]; then
        local dns_constraints=""
        local dns_idx=0
        IFS=',' read -ra _domains <<< "$dns_domains"
        for _domain in "${_domains[@]}"; do
            _domain=$(echo "$_domain" | xargs)  # trim whitespace
            dns_constraints+="permitted;DNS.${dns_idx}  = ${_domain}"$'\n'
            dns_idx=$((dns_idx + 1))
        done
        # Always include cluster.local for in-cluster services
        dns_constraints+="permitted;DNS.${dns_idx}  = cluster.local"

        nc_block="nameConstraints        = critical, @name_constraints

[name_constraints]
${dns_constraints}
permitted;IP.0   = 10.0.0.0/255.0.0.0
permitted;IP.1   = 172.16.0.0/255.240.0.0
permitted;IP.2   = 192.168.0.0/255.255.0.0"
    fi

    local conf_file
    conf_file=$(mktemp)
    cat > "$conf_file" <<EOF
[req]
distinguished_name = req_dn
x509_extensions    = v3_root_ca
prompt             = no

[req_dn]
O  = ${ORG}
CN = ${cn}

[v3_root_ca]
basicConstraints       = critical, CA:true
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
${nc_block}
EOF

    # Create self-signed root CA certificate
    openssl req -x509 -new -nodes \
        -key "$key_path" \
        -sha256 \
        -days "$ROOT_DAYS" \
        -out "$cert_path" \
        -config "$conf_file"

    rm -f "$conf_file"

    log "Root CA certificate: ${cert_path}"
    log "Root CA private key: ${key_path} (KEEP OFFLINE — never commit)"

    echo ""
    openssl x509 -in "$cert_path" -noout -subject -issuer -dates -fingerprint -sha256
}

# =============================================================================
# Command: intermediate
# =============================================================================
cmd_intermediate() {
    if [[ -z "$NAME" ]]; then
        err "-n NAME is required for intermediate command"
        usage
    fi
    if [[ -z "$ROOT_CERT" || -z "$ROOT_KEY" ]]; then
        err "--root-cert and --root-key are required for intermediate command"
        usage
    fi
    if [[ ! -f "$ROOT_CERT" ]]; then
        err "Root CA certificate not found: $ROOT_CERT"
        exit 1
    fi
    if [[ ! -f "$ROOT_KEY" ]]; then
        err "Root CA private key not found: $ROOT_KEY"
        exit 1
    fi

    local cert_path="${OUTPUT_DIR}/${NAME}-ca.pem"
    local key_path="${OUTPUT_DIR}/${NAME}-ca-key.pem"
    local chain_path="${OUTPUT_DIR}/ca-chain.pem"
    local csr_path
    csr_path=$(mktemp)

    mkdir -p "$OUTPUT_DIR"
    check_file_exists "$cert_path"
    check_file_exists "$key_path"
    check_file_exists "$chain_path"

    local cn="${ORG} ${NAME} CA"
    # Capitalize words in the CN for readability
    cn=$(echo "$cn" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

    log "Generating Intermediate CA: CN=${cn}"
    log "Signed by: $(openssl x509 -in "$ROOT_CERT" -noout -subject | sed 's/subject=//')"
    log "Validity: ${INTERMEDIATE_DAYS} days (~$((INTERMEDIATE_DAYS / 365)) years)"
    log "Output: ${OUTPUT_DIR}/"

    # Generate RSA 4096-bit key
    openssl genrsa -out "$key_path" 4096 2>/dev/null
    chmod 600 "$key_path"

    # Create CSR
    openssl req -new \
        -key "$key_path" \
        -out "$csr_path" \
        -subj "/O=${ORG}/CN=${cn}"

    # Create extensions file for intermediate CA
    local ext_file
    ext_file=$(mktemp)
    cat > "$ext_file" <<EOF
[v3_intermediate_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

    # Sign intermediate cert with root CA
    openssl x509 -req \
        -in "$csr_path" \
        -CA "$ROOT_CERT" \
        -CAkey "$ROOT_KEY" \
        -CAcreateserial \
        -out "$cert_path" \
        -days "$INTERMEDIATE_DAYS" \
        -sha256 \
        -extfile "$ext_file" \
        -extensions v3_intermediate_ca

    # Build chain file (intermediate + root)
    cat "$cert_path" "$ROOT_CERT" > "$chain_path"

    rm -f "$csr_path" "$ext_file"

    log "Intermediate CA certificate: ${cert_path}"
    log "Intermediate CA private key: ${key_path} (gitignored)"
    log "Full chain (intermediate + root): ${chain_path}"

    echo ""
    openssl x509 -in "$cert_path" -noout -subject -issuer -dates -fingerprint -sha256

    echo ""
    log "Verifying chain of trust..."
    if openssl verify -CAfile "$ROOT_CERT" "$cert_path" >/dev/null 2>&1; then
        log "Chain verification: PASSED"
    else
        err "Chain verification: FAILED"
        exit 1
    fi
}

# =============================================================================
# Command: leaf
# =============================================================================
cmd_leaf() {
    if [[ -z "$NAME" ]]; then
        err "-n NAME is required for leaf command"
        usage
    fi
    if [[ -z "$CA_CERT" || -z "$CA_KEY" ]]; then
        err "--ca-cert and --ca-key are required for leaf command"
        usage
    fi
    if [[ ! -f "$CA_CERT" ]]; then
        err "Signing CA certificate not found: $CA_CERT"
        exit 1
    fi
    if [[ ! -f "$CA_KEY" ]]; then
        err "Signing CA private key not found: $CA_KEY"
        exit 1
    fi
    if [[ -z "$SAN" ]]; then
        err "--san is required for leaf command (e.g. --san DNS:foo.example.com,DNS:bar.example.com)"
        usage
    fi

    local cert_path="${OUTPUT_DIR}/${NAME}.pem"
    local key_path="${OUTPUT_DIR}/${NAME}-key.pem"
    local fullchain_path="${OUTPUT_DIR}/${NAME}-fullchain.pem"
    local csr_path
    csr_path=$(mktemp)

    mkdir -p "$OUTPUT_DIR"
    check_file_exists "$cert_path"
    check_file_exists "$key_path"
    check_file_exists "$fullchain_path"

    # Build CN from the first DNS SAN, or fallback to NAME
    local cn=""
    local first_dns
    first_dns=$(echo "$SAN" | tr ',' '\n' | grep -m1 '^DNS:' | sed 's/^DNS://' || true)
    if [[ -n "$first_dns" ]]; then
        cn="$first_dns"
    else
        cn="$NAME"
    fi

    log "Generating leaf certificate: CN=${cn}"
    log "Signed by: $(openssl x509 -in "$CA_CERT" -noout -subject | sed 's/subject=//')"
    log "Validity: ${LEAF_DAYS} days (~$((LEAF_DAYS / 365)) year(s))"
    log "Key type: ${KEY_TYPE}"
    log "Output: ${OUTPUT_DIR}/"

    # Generate key based on type
    case "$KEY_TYPE" in
        ecdsa)
            openssl ecparam -name prime256v1 -genkey -noout -out "$key_path" 2>/dev/null
            ;;
        rsa)
            openssl genrsa -out "$key_path" 4096 2>/dev/null
            ;;
        *)
            err "Unknown key type: $KEY_TYPE (use 'ecdsa' or 'rsa')"
            exit 1
            ;;
    esac
    chmod 600 "$key_path"

    # Create CSR
    openssl req -new \
        -key "$key_path" \
        -out "$csr_path" \
        -subj "/O=${ORG}/CN=${cn}"

    # Build SAN extension string
    local san_ext="subjectAltName = "
    san_ext+="$SAN"

    # Create extensions file for leaf certificate
    local ext_file
    ext_file=$(mktemp)
    cat > "$ext_file" <<EOF
[v3_leaf]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
${san_ext}
EOF

    # Sign with CA
    openssl x509 -req \
        -in "$csr_path" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$cert_path" \
        -days "$LEAF_DAYS" \
        -sha256 \
        -extfile "$ext_file" \
        -extensions v3_leaf

    rm -f "$csr_path" "$ext_file"

    # Build fullchain: leaf + chain
    # Look for ca-chain.pem alongside the CA cert (intermediate + root)
    local ca_dir
    ca_dir=$(dirname "$CA_CERT")
    local chain_file="${ca_dir}/ca-chain.pem"

    if [[ -f "$chain_file" ]]; then
        cat "$cert_path" "$chain_file" > "$fullchain_path"
        log "Fullchain built using: ${chain_file}"
    else
        # Fallback: leaf + CA cert only
        cat "$cert_path" "$CA_CERT" > "$fullchain_path"
        warn "No ca-chain.pem found alongside CA cert — fullchain contains leaf + CA only"
    fi

    log "Leaf certificate: ${cert_path}"
    log "Leaf private key: ${key_path} (KEEP SECRET)"
    log "Fullchain: ${fullchain_path}"

    echo ""
    openssl x509 -in "$cert_path" -noout -subject -issuer -dates -fingerprint -sha256

    echo ""
    log "SANs:"
    openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null || \
        openssl x509 -in "$cert_path" -noout -text | grep -A1 "Subject Alternative Name"

    # Verify chain
    echo ""
    log "Verifying chain of trust..."
    if [[ -f "$chain_file" ]]; then
        if openssl verify -CAfile "$chain_file" "$cert_path" >/dev/null 2>&1; then
            log "Chain verification: PASSED"
        else
            err "Chain verification: FAILED"
            exit 1
        fi
    else
        if openssl verify -CAfile "$CA_CERT" "$cert_path" >/dev/null 2>&1; then
            log "Chain verification: PASSED"
        else
            err "Chain verification: FAILED"
            exit 1
        fi
    fi
}

# =============================================================================
# Command: verify
# =============================================================================
cmd_verify() {
    local chain_file="${ROOT_CERT:-}"
    if [[ -z "$chain_file" ]]; then
        err "Chain file path is required for verify command"
        echo "Usage: $0 verify CHAIN_FILE"
        exit 1
    fi
    if [[ ! -f "$chain_file" ]]; then
        err "Chain file not found: $chain_file"
        exit 1
    fi

    log "Verifying certificate chain: $chain_file"
    echo ""

    # Count certificates in the chain
    local cert_count
    cert_count=$(grep -c 'BEGIN CERTIFICATE' "$chain_file")
    log "Certificates in chain: $cert_count"
    echo ""

    # Display each certificate in the chain
    local idx=0
    local tmpfile
    tmpfile=$(mktemp)

    # Split chain into individual certs and display
    csplit -z -f "${tmpfile}." "$chain_file" '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true

    for cert_file in "${tmpfile}."*; do
        if [[ -s "$cert_file" ]] && grep -q 'BEGIN CERTIFICATE' "$cert_file"; then
            idx=$((idx + 1))
            echo -e "${GREEN}--- Certificate ${idx} ---${NC}"
            openssl x509 -in "$cert_file" -noout -subject -issuer -dates \
                -ext basicConstraints,keyUsage 2>/dev/null || true
            echo ""
        fi
        rm -f "$cert_file"
    done
    rm -f "$tmpfile"

    # Verify the chain itself
    if [[ "$cert_count" -ge 2 ]]; then
        # Extract root (last cert) and leaf (first cert)
        local root_tmp leaf_tmp
        root_tmp=$(mktemp)
        leaf_tmp=$(mktemp)

        # Last cert = root
        awk '/-----BEGIN CERTIFICATE-----/{c++} c=='"$cert_count" "$chain_file" > "$root_tmp"
        # First cert = leaf/intermediate
        awk '/-----BEGIN CERTIFICATE-----/{c++} c==1' "$chain_file" > "$leaf_tmp"

        if openssl verify -CAfile "$root_tmp" "$leaf_tmp" >/dev/null 2>&1; then
            log "Chain verification: PASSED"
        else
            err "Chain verification: FAILED"
            rm -f "$root_tmp" "$leaf_tmp"
            exit 1
        fi
        rm -f "$root_tmp" "$leaf_tmp"
    else
        log "Single certificate (self-signed root) — no chain to verify"
        if openssl verify -CAfile "$chain_file" "$chain_file" >/dev/null 2>&1; then
            log "Self-signed verification: PASSED"
        else
            warn "Self-signed verification: FAILED (may be an intermediate without its root)"
        fi
    fi
}

# =============================================================================
# Dispatch
# =============================================================================
case "$COMMAND" in
    root)         cmd_root ;;
    intermediate) cmd_intermediate ;;
    leaf)         cmd_leaf ;;
    verify)       cmd_verify ;;
    -h|--help)    usage ;;
    *)            err "Unknown command: $COMMAND"; usage ;;
esac
