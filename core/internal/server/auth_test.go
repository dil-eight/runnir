//go:build !windows

package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

const testSecret = "0123456789abcdef0123456789abcdef"

func withSecret(ctx context.Context, secret string) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+secret)
}

func TestOnlyTheClientWithTheSecretCanUseTheCore(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{ClientSecret: []byte(testSecret)})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// HealthCheck stays open so a supervisor can see the Core answer.
	if _, err := client.HealthCheck(ctx, &corev1.HealthCheckRequest{}); err != nil {
		t.Fatalf("health without secret: %v", err)
	}
	root := t.TempDir()
	for name, callCtx := range map[string]context.Context{
		"no secret":    ctx,
		"wrong secret": withSecret(ctx, "ffffffffffffffffffffffffffffffff"),
	} {
		if _, err := client.OpenRepository(callCtx, &corev1.OpenRepositoryRequest{Path: root}); status.Code(err) != codes.Unauthenticated {
			t.Errorf("%s: open = %v, want Unauthenticated", name, err)
		}
		if _, err := client.SetGitHubCredential(callCtx, &corev1.SetGitHubCredentialRequest{Token: "ghu_x"}); status.Code(err) != codes.Unauthenticated {
			t.Errorf("%s: set credential = %v, want Unauthenticated", name, err)
		}
		stream, err := client.SubscribeEvents(callCtx, &corev1.SubscribeEventsRequest{})
		if err == nil {
			_, err = stream.Recv()
		}
		if status.Code(err) != codes.Unauthenticated {
			t.Errorf("%s: subscribe = %v, want Unauthenticated", name, err)
		}
	}

	authed := withSecret(ctx, testSecret)
	if _, err := client.OpenRepository(authed, &corev1.OpenRepositoryRequest{Path: root}); err != nil {
		t.Fatalf("open with secret: %v", err)
	}
	stream, err := client.SubscribeEvents(authed, &corev1.SubscribeEventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if event, err := stream.Recv(); err != nil || event.Type != corev1.CoreEventType_CORE_EVENT_TYPE_CORE_READY {
		t.Fatalf("stream with secret = %v, %v", event, err)
	}
}

func TestGitHubCredentialIsHeldButNeverReturned(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	health := func() *corev1.HealthCheckResponse {
		t.Helper()
		h, err := client.HealthCheck(ctx, &corev1.HealthCheckRequest{})
		if err != nil {
			t.Fatal(err)
		}
		return h
	}
	if health().GithubCredentialSet {
		t.Fatal("credential set before any call")
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "bad token"}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("invalid token = %v", err)
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_valid"}); err != nil {
		t.Fatal(err)
	}
	h := health()
	if !h.GithubCredentialSet || strings.Contains(h.String(), "ghu_valid") {
		t.Fatalf("health = %v", h)
	}
	if _, err := client.ClearGitHubCredential(ctx, &corev1.ClearGitHubCredentialRequest{}); err != nil {
		t.Fatal(err)
	}
	if health().GithubCredentialSet {
		t.Fatal("credential still set after clear")
	}
}
