package server

import (
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestValuesAreRefusedWhereActCannotGetThem(t *testing.T) {
	withValues := &corev1.ConfirmLocalRunRequest{Secrets: map[string]string{"A": "x"}}
	if err := valuesSupported(false, withValues); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("without pipes = %v", err)
	}
	if err := valuesSupported(false, &corev1.ConfirmLocalRunRequest{}); err != nil {
		t.Fatalf("no values without pipes = %v", err)
	}
	if err := valuesSupported(true, withValues); err != nil {
		t.Fatalf("with pipes = %v", err)
	}
}
