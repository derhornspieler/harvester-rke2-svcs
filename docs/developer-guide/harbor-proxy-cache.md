# Harbor Proxy-Cache for CI Images

All container images used in CI pipelines and Kubernetes workloads must be
pulled through the Harbor proxy-cache at `harbor.example.com`. Direct pulls
from upstream registries are blocked by network policy.

---

## Why Proxy-Cache Is Required

1. **Air-gap support.** The cluster operates behind restricted egress rules.
   Harbor is the only registry endpoint reachable from worker nodes and CI
   runner pods. Direct pulls from Docker Hub, Quay, or GHCR will fail.

2. **Supply chain security.** Every image pulled through Harbor is scanned by
   Trivy before it reaches workloads. The proxy-cache provides a controlled
   ingestion point where vulnerable or unsigned images can be blocked.

3. **Rate limit avoidance.** Docker Hub enforces pull rate limits (100
   pulls/6h for anonymous, 200 for authenticated). Harbor caches images
   locally after the first pull, eliminating rate limit failures during
   CI bursts or node scaling events.

4. **Availability.** If an upstream registry experiences an outage, cached
   images remain available from Harbor. This prevents CI pipeline failures
   and pod scheduling delays caused by external dependencies.

---

## How to Reference Images

Replace the upstream registry prefix with `harbor.example.com/<project>/`:

```
harbor.example.com/<project>/<image>:<tag>
```

### Supported Registries

| Upstream Registry | Harbor Project | Example |
|-------------------|---------------|---------|
| `docker.io` (Docker Hub) | `dockerhub` | `harbor.example.com/dockerhub/library/alpine:3.23` |
| `quay.io` | `quay` | `harbor.example.com/quay/prometheus/prometheus:v3.4.0` |
| `ghcr.io` | `ghcr` | `harbor.example.com/ghcr/aquasecurity/trivy:0.69.0` |
| `registry.k8s.io` | `k8s` | `harbor.example.com/k8s/ingress-nginx/controller:v1.12.0` |

### Image Reference Rules

**Docker Hub official images** include `library/` in the path:

```yaml
# Upstream: docker.io/alpine:3.23 (official image)
# Proxy:
image: harbor.example.com/dockerhub/library/alpine:3.23

# Upstream: docker.io/grafana/grafana:11.6.0 (community image)
# Proxy:
image: harbor.example.com/dockerhub/grafana/grafana:11.6.0
```

**Quay, GHCR, and registry.k8s.io** keep their original path after the
Harbor project prefix:

```yaml
# Upstream: quay.io/cilium/cilium:v1.17.1
# Proxy:
image: harbor.example.com/quay/cilium/cilium:v1.17.1

# Upstream: ghcr.io/external-secrets/external-secrets:v0.14.4
# Proxy:
image: harbor.example.com/ghcr/external-secrets/external-secrets:v0.14.4

# Upstream: registry.k8s.io/sig-storage/csi-provisioner:v5.2.0
# Proxy:
image: harbor.example.com/k8s/sig-storage/csi-provisioner:v5.2.0
```

### CI Pipeline Examples

Reference proxy-cache images in `.gitlab-ci.yml`:

```yaml
# Build job using Buildah through proxy-cache
build:
  image: harbor.example.com/quay/buildah/buildah:v1.39.0
  script:
    - buildah bud --layers -t "${IMAGE}:${CI_COMMIT_SHORT_SHA}" .

# Scan job using Trivy through proxy-cache
scan:
  image: harbor.example.com/ghcr/aquasecurity/trivy:0.69.0
  script:
    - trivy image --severity HIGH,CRITICAL --exit-code 1 "${IMAGE}"

# Lint job using golangci-lint through proxy-cache
lint:
  image: harbor.example.com/dockerhub/golangci/golangci-lint:v2.1.0
  script:
    - golangci-lint run ./...
```

### Dockerfile Base Images

Use proxy-cache references in Dockerfiles too. This ensures builds work
inside the cluster where upstream registries are unreachable:

```dockerfile
# Use proxy-cache for base images
FROM harbor.example.com/dockerhub/library/golang:1.24-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o /app/server .

FROM harbor.example.com/dockerhub/library/alpine:3.23
COPY --from=builder /app/server /usr/local/bin/server
ENTRYPOINT ["server"]
```

---

## Pinning Images to Digests

For CI pipelines and production workloads, pin images to their SHA256 digest
alongside the human-readable tag. This prevents tag-replacement supply chain
attacks.

```yaml
# Pin to digest with tag as comment
image: harbor.example.com/ghcr/aquasecurity/trivy:0.69.0@sha256:abc123...
```

Get the digest for any image using `skopeo`:

```bash
skopeo inspect docker://harbor.example.com/ghcr/aquasecurity/trivy:0.69.0 \
  | jq -r '.Digest'
```

Or inspect the upstream image before it is cached:

```bash
skopeo inspect docker://ghcr.io/aquasecurity/trivy:0.69.0 \
  | jq -r '.Digest'
```

---

## Adding a New Proxy-Cache Project

If you need images from a registry that is not yet proxied, request a new
proxy-cache project from the platform team.

### Prerequisites

- Harbor admin access (platform team only)
- The upstream registry must be publicly accessible (or have credentials
  configured in Harbor)

### Steps (Platform Team)

1. Log in to Harbor at `https://harbor.example.com`
2. Navigate to **Administration > Registries**
3. Click **+ New Endpoint** and configure:
   - **Provider**: Select the registry type (Docker Hub, Quay, GHCR, etc.)
   - **Endpoint URL**: The upstream registry URL (e.g., `https://gcr.io`)
   - **Access ID/Secret**: Credentials if the registry requires auth
4. Click **Test Connection** to verify reachability
5. Navigate to **Projects > New Project**:
   - **Project Name**: Short lowercase name (e.g., `gcr`)
   - **Access Level**: Public (so all cluster workloads can pull)
   - **Proxy Cache**: Enable and select the registry endpoint from step 3
6. Test the proxy-cache by pulling an image:
   ```bash
   skopeo inspect docker://harbor.example.com/gcr/distroless/static:nonroot
   ```
7. Update this document with the new registry mapping

### Requesting a New Proxy-Cache

Open an issue in the `harvester-rke2-svcs` project with:

- **Title**: `feat: add Harbor proxy-cache for <registry>`
- **Registry URL**: The upstream registry endpoint
- **Example images**: 2-3 images you need from this registry
- **Justification**: Why existing registries do not cover your use case

---

## Troubleshooting

### "manifest unknown" or "not found" on first pull

The first pull through the proxy-cache triggers a fetch from upstream. This
can take longer than a normal pull. If it times out, retry the pull. Harbor
caches the manifest and layers after the first successful fetch.

### "unauthorized" when pulling from proxy-cache

- Verify the Harbor project is set to **Public** access level
- Check that the proxy-cache endpoint has valid credentials (for registries
  that require auth)
- Confirm you are using the correct project name in the image reference

### Image is outdated or stale

Harbor caches images and refreshes them based on the project's configured
cache duration (default: 168 hours / 7 days). To force a refresh:

1. Log in to Harbor UI
2. Navigate to the proxy-cache project
3. Delete the cached repository
4. Pull the image again to fetch the latest version

### Rate limit errors from upstream

If Harbor logs show rate limit errors from Docker Hub, ensure the registry
endpoint has Docker Hub credentials configured (a free account provides
200 pulls/6h instead of 100).

---

## Reference

- [GitLab CI Patterns](gitlab-ci.md) -- CI pipeline image configuration
- [Application Design](application-design.md) -- Dockerfile and image patterns
- [Supply Chain Security](gitlab-ci.md#supply-chain-security) -- image pinning
- [Secrets & Configuration](../architecture/secrets-configuration.md) -- Vault paths
