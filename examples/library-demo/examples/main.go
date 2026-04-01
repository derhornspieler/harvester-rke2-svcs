package main

import (
	"fmt"

	sharedlib "github.com/your-org/shared-library"
)

func main() {
	// Use RequestID from shared library
	id := sharedlib.RequestID()
	fmt.Printf("Request ID: %s\n", id)

	// Use HealthStatus from shared library
	hs := sharedlib.NewHealthStatus()
	fmt.Printf("Health: %s at %s\n", hs.Status, hs.Timestamp)
}
