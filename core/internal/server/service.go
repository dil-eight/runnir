package server

import (
	"context"
	"runtime"

	"runnir/core/internal/buildinfo"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// service implements the RunnirCore RPCs. Unimplemented methods return
// codes.Unimplemented until their phase lands.
type service struct {
	corev1.UnimplementedRunnirCoreServer
}

func (s *service) HealthCheck(context.Context, *corev1.HealthCheckRequest) (*corev1.HealthCheckResponse, error) {
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	return &corev1.HealthCheckResponse{
		CoreVersion:     buildinfo.Version,
		ProtocolVersion: buildinfo.ProtocolVersion,
		// Go runtime's total memory obtained from the OS; a coarse stand-in
		// for resident size until the diagnostics phase.
		ResidentMemoryBytes: memory.Sys,
	}, nil
}
