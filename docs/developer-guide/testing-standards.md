# Testing Standards and Acceptance Criteria

Testing requirements for all services deployed on the Harvester RKE2 platform.
These standards apply to both application teams and platform operators.

---

## Test Pyramid

Structure your test suite as a pyramid: many fast unit tests at the base,
fewer integration tests in the middle, and a small number of E2E tests at
the top.

```
         /   E2E    \          Few: critical user journeys only
        / Integration \        Some: API contracts, service boundaries
       /   Unit Tests   \      Many: business logic, edge cases, utils
```

**Unit tests** run in milliseconds and cover individual functions, data
transformations, and business rules. They never touch the network, database,
or filesystem.

**Integration tests** verify interactions between components: API endpoints,
database queries, message queue consumers, and external service clients. They
may use test fixtures (CNPG test databases, Valkey containers) but never hit
production services.

**E2E tests** exercise full user journeys through the deployed system. They
are slow, flaky-prone, and expensive. Write them only for critical paths
where a failure would cause an outage or data loss.

---

## Coverage Targets

| Layer | Target | Enforcement |
|-------|--------|-------------|
| Unit | 80% line coverage minimum | CI gate (fail below threshold) |
| Integration | All critical API paths covered | CI gate (contract tests) |
| E2E | Happy path + top 3 failure modes | Nightly or pre-release run |
| Security | SAST + DAST on every MR | CI gate (Trivy, Semgrep) |

### Measuring Coverage

**Go:**

```yaml
test:
  stage: test
  script:
    - go test -race -coverprofile=coverage.out ./...
    - go tool cover -func=coverage.out
  coverage: '/total:\s+\(statements\)\s+(\d+\.\d+)%/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.xml
```

**JavaScript/TypeScript:**

```yaml
test:
  stage: test
  script:
    - npm ci
    - npx jest --coverage --coverageReporters=text --coverageReporters=cobertura
  coverage: '/All files\s*\|\s*(\d+\.\d+)/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage/cobertura-coverage.xml
```

**Python:**

```yaml
test:
  stage: test
  script:
    - pip install -r requirements-dev.txt
    - pytest --cov=src --cov-report=term --cov-report=xml:coverage.xml
  coverage: '/TOTAL\s+\d+\s+\d+\s+(\d+)%/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.xml
```

---

## Required Tests by Change Type

Every change must include tests appropriate to its type. MR reviewers enforce
this before approving.

| Change Type | Required Tests | Notes |
|-------------|---------------|-------|
| New feature | Unit + integration + acceptance criteria | Acceptance criteria use GIVEN/WHEN/THEN format |
| Bug fix | Regression test proving the fix | Test must fail before the fix, pass after |
| Refactor | Existing tests pass unchanged | No new tests needed unless coverage drops |
| Config change | Smoke test in staging | Verify the service starts and responds |
| Dependency update | Full test suite + security scan | Trivy filesystem scan catches new CVEs |
| API change | Contract tests updated | Consumers must not break |

### Acceptance Criteria Format

Every feature MR must include acceptance criteria in the description:

```
## Acceptance Criteria

- GIVEN a user with role "developer"
  WHEN they push to a feature branch
  THEN the lint and test stages run automatically

- GIVEN a failed security scan
  WHEN the MR attempts to merge
  THEN GitLab blocks the merge with a clear error message
```

---

## CI Pipeline Test Gates

Tests run at specific pipeline stages. All gates must pass before merge.

### MR Pipeline Gates

These run on every merge request and block the merge if they fail:

| Gate | Stage | Tool | Pass Criteria |
|------|-------|------|---------------|
| Linting | `lint` | Language-specific linter | Zero errors |
| Unit tests | `test` | Language test framework | All pass, coverage threshold met |
| Secret detection | `lint` | Gitleaks | Zero findings |
| SAST | `scan` | Semgrep | No HIGH or CRITICAL findings |
| Dependency scan | `scan` | Trivy filesystem | No HIGH or CRITICAL CVEs |

### Main Branch Gates

These run after merge to `main` and block the deployment if they fail:

| Gate | Stage | Tool | Pass Criteria |
|------|-------|------|---------------|
| Container scan | `scan` | Trivy image | No HIGH or CRITICAL CVEs |
| SBOM generation | `scan` | Syft | Artifact generated and archived |
| License check | `scan` | Trivy license | No copyleft in production deps |

### Configuring Test Gates

Use the platform CI Catalog components to set up gates automatically:

```yaml
include:
  - component: gitlab.<DOMAIN>/infra_and_platform_services/ci-components/lint@1.0.0
    inputs:
      coverage_threshold: 80

  - component: gitlab.<DOMAIN>/infra_and_platform_services/ci-components/scan@1.0.0
```

Override the coverage threshold per project if needed. Never set it below 60%.

---

## When to Write Regression Tests

Write a regression test whenever:

1. **A bug is reported and fixed.** The test must reproduce the original bug
   (fail without the fix) and pass with the fix applied. Name the test after
   the issue number: `TestBug42_NilPointerOnEmptyInput`.

2. **A CI pipeline catches a defect.** If a scan or lint rule catches
   something that should have been caught by a test, add the test so
   future regressions are caught earlier (shift left).

3. **A production incident occurs.** After root cause analysis, add a test
   that would have prevented the incident. Document the link between the
   test and the incident in a code comment.

4. **An edge case is discovered during code review.** If a reviewer
   identifies an unhandled case, the fix must include a test covering it.

### Regression Test Naming

Use descriptive names that explain the scenario, not the implementation:

```go
// Good
func TestVaultAuth_RejectsExpiredJWT(t *testing.T) { ... }
func TestHarborPush_HandlesNetworkTimeout(t *testing.T) { ... }

// Bad
func TestFix123(t *testing.T) { ... }
func TestEdgeCase(t *testing.T) { ... }
```

### Tracking Regressions

Track known regressions in the project issue tracker with the `regression`
label. Each regression issue must include:

- **Trigger**: What change introduced the regression
- **Symptom**: What users or systems observed
- **Test**: Link to the regression test that now covers it
- **Status**: Open, fixed, or verified

---

## Test Environment Conventions

### Database Tests (CNPG)

Use ephemeral CNPG test clusters for integration tests that need PostgreSQL.
Never test against production databases.

```yaml
integration-test:
  services:
    - name: postgres:17-alpine
      alias: testdb
  variables:
    PGHOST: testdb
    PGUSER: test
    PGPASSWORD: test
    PGDATABASE: testdb
  script:
    - go test -tags=integration ./...
```

### Cache Tests (Valkey)

Use ephemeral Valkey instances for tests that need a cache layer:

```yaml
integration-test:
  services:
    - name: valkey/valkey:8-alpine
      alias: cache
  variables:
    REDIS_URL: redis://cache:6379
  script:
    - go test -tags=integration ./...
```

### Object Storage Tests (MinIO)

Use a MinIO container for tests that interact with S3-compatible storage:

```yaml
integration-test:
  services:
    - name: minio/minio:latest
      alias: minio
      command: ["server", "/data"]
  variables:
    AWS_ENDPOINT_URL: http://minio:9000
    AWS_ACCESS_KEY_ID: minioadmin
    AWS_SECRET_ACCESS_KEY: minioadmin
  script:
    - go test -tags=integration ./...
```

---

## Performance Testing

For services with latency or throughput requirements, establish baselines
and test before major releases.

### When to Performance Test

| Trigger | Action |
|---------|--------|
| New service launch | Establish baseline (latency p50/p95/p99, throughput) |
| Major release | Load test to verify no regression |
| Database schema change | Query performance check (explain plans) |
| Scaling change | Verify HPA behavior under load |

### Tools

- **k6** for HTTP load testing (preferred, runs in CI)
- **Go benchmarks** for function-level performance (`go test -bench`)
- **EXPLAIN ANALYZE** for PostgreSQL query validation

### Resource Validation

Verify that resource requests are sufficient under load. A service should
not OOM-kill or CPU-throttle during normal peak traffic:

```bash
# Check for OOM kills after load test
kubectl get events -n <TEAM> --field-selector reason=OOMKilling
```

---

## Reference

- [GitLab CI Patterns](gitlab-ci.md) -- CI/CD pipeline configuration
- [Application Design](application-design.md) -- resource limits, health probes
- [Platform Integration](platform-integration.md) -- monitoring and observability
- [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) -- system design
