package sharedlib

import (
	"fmt"
	"time"
)

// RequestID generates a unique request identifier
func RequestID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

// HealthStatus represents service health
type HealthStatus struct {
	Status    string
	Timestamp time.Time
}

// NewHealthStatus creates a healthy status
func NewHealthStatus() HealthStatus {
	return HealthStatus{
		Status:    "healthy",
		Timestamp: time.Now(),
	}
}
