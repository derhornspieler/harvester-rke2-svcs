package sharedlib

import (
	"testing"
)

func TestRequestID(t *testing.T) {
	id1 := RequestID()
	id2 := RequestID()

	if id1 == id2 {
		t.Error("RequestID should be unique")
	}

	if id1 == "" {
		t.Error("RequestID should not be empty")
	}
}

func TestNewHealthStatus(t *testing.T) {
	hs := NewHealthStatus()

	if hs.Status != "healthy" {
		t.Errorf("Expected status 'healthy', got '%s'", hs.Status)
	}

	if hs.Timestamp.IsZero() {
		t.Error("Timestamp should not be zero")
	}
}
