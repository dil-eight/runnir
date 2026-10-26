package server

import (
	"context"
	"unicode/utf8"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/dotenv"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// ParseEnvFile parses a .env file the app read from a file the user picked.
// The Core takes the bytes, not a path, so it reads no file outside the
// repositories it opened.
func (s *service) ParseEnvFile(_ context.Context, request *corev1.ParseEnvFileRequest) (*corev1.ParseEnvFileResponse, error) {
	data := request.GetContent()
	if len(data) > dotenv.MaxSize {
		return nil, status.Error(codes.InvalidArgument, "the file is larger than 1 MiB")
	}
	if !utf8.Valid(data) {
		return nil, status.Error(codes.InvalidArgument, "the file is not UTF-8 text")
	}
	entries, problems := dotenv.Parse(data)
	out := &corev1.ParseEnvFileResponse{}
	for _, entry := range entries {
		out.Entries = append(out.Entries, &corev1.EnvEntry{Name: entry.Name, Value: entry.Value, Encrypted: entry.Encrypted, Line: uint32(entry.Line)})
	}
	for _, problem := range problems {
		out.Problems = append(out.Problems, &corev1.EnvProblem{Line: uint32(problem.Line), Message: problem.Message})
	}
	return out, nil
}
