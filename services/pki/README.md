# PKI Service

Offline Root CA and certificate generation tooling for the PKI hierarchy.

## Hierarchy

    Offline Root CA (30yr, RSA 4096, nameConstraints)
      └── Vault Intermediate CA (pathlen:0, key inside Vault only)
            └── cert-manager vault-issuer → leaf TLS certs

## Usage

Generate a new Root CA (only needed once):

    ./generate-ca.sh root -o "My Organization" -d roots/

Generate a new intermediate for Vault (only needed during initial bootstrap):

    ./generate-ca.sh intermediate -n vault-int \
        --root-cert roots/root-ca.pem \
        --root-key roots/root-ca-key.pem \
        -d intermediates/vault/

Verify a certificate chain:

    ./generate-ca.sh verify intermediates/vault/ca-chain.pem

## Security

- Root CA key (`*-key.pem`) is gitignored and stored offline
- Vault intermediate key lives inside Vault only
- nameConstraints restrict all certs to: your domain, cluster.local, RFC 1918
