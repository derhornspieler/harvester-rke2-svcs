# Vault Intermediate CA

The Vault intermediate CA private key is generated INSIDE Vault's `pki_int` backend
and never exported to disk.

During deployment (`deploy-pki-secrets.sh` Phase 3):
1. Vault generates an intermediate CSR internally
2. The CSR is signed locally using the Root CA key
3. The signed certificate chain is imported back into Vault
4. The private key never leaves Vault's barrier encryption

To inspect the intermediate certificate:
    vault read pki_int/ca/pem
