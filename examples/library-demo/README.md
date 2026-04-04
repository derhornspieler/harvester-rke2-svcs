# Shared Library Demo

Example of a reusable Go library published to GitLab Package Registry.

## What This Demonstrates

- Go module structure
- Unit tests
- Publishing to GitLab Package Registry
- How to import and use in other services
- Semantic versioning

## Quick Start

### 1. Clone This Repo

```bash
git clone https://github.com/your-org/shared-library.git
cd shared-library
```

### 2. Run Tests

```bash
go test -v ./...
```

### 3. Use in Your Service

In your service's `go.mod`, add:

```text
require github.com/your-org/shared-library v1.0.0
```

Then in your code:

```go
import "github.com/your-org/shared-library"

func main() {
    id := sharedlib.RequestID()
    hs := sharedlib.NewHealthStatus()
}
```

## File Structure

```text
library.go              # Public API
library_test.go         # Unit tests
go.mod                  # Module definition
.gitlab-ci.yml          # CI/CD pipeline
examples/
    main.go             # How to use the library
README.md               # This file
```

## Publishing

Push a Git tag to trigger publication:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitLab CI will publish to the Package Registry automatically.

## Next Steps

- Import this library in microservice-demo
- Add more utility functions
- Create versions and tags
