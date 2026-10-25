package server

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"unicode/utf8"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/dotenv"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// ReadEnvFile reads a .env file the user picked in the app. The path is the
// user's own choice, so a symbolic link is followed.
func (s *service) ReadEnvFile(_ context.Context, request *corev1.ReadEnvFileRequest) (*corev1.ReadEnvFileResponse, error) {
	path := request.GetPath()
	if !filepath.IsAbs(path) {
		return nil, status.Error(codes.InvalidArgument, "choose a file")
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	if !info.Mode().IsRegular() {
		return nil, status.Error(codes.InvalidArgument, "this is not a file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, dotenv.MaxSize+1))
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	if len(data) > dotenv.MaxSize {
		return nil, status.Error(codes.InvalidArgument, "the file is larger than 1 MiB")
	}
	if !utf8.Valid(data) {
		return nil, status.Error(codes.InvalidArgument, "the file is not UTF-8 text")
	}
	entries, problems := dotenv.Parse(data)
	out := &corev1.ReadEnvFileResponse{}
	for _, entry := range entries {
		out.Entries = append(out.Entries, &corev1.EnvEntry{Name: entry.Name, Value: entry.Value, Encrypted: entry.Encrypted, Line: uint32(entry.Line)})
	}
	for _, problem := range problems {
		out.Problems = append(out.Problems, &corev1.EnvProblem{Line: uint32(problem.Line), Message: problem.Message})
	}
	return out, nil
}
