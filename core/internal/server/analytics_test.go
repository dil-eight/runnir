//go:build !windows

package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/scanner"
)

func analyticsClient(t *testing.T, options Options) corev1.RunnirCoreClient {
	t.Helper()
	path := socketPath(t)
	stop := startWith(t, path, options)
	t.Cleanup(func() { _ = stop() })
	conn, err := grpc.NewClient("unix://"+path, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return corev1.NewRunnirCoreClient(conn)
}

func counted(counters []*corev1.AnalyticsCounter, name string) uint64 {
	for _, c := range counters {
		if c.GetName() == name {
			return c.GetValue()
		}
	}
	return 0
}

func TestAnalyticsOverGRPC(t *testing.T) {
	var mu sync.Mutex
	var sent []string
	posthog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Batch []struct{ Event string } `json:"batch"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		for _, e := range body.Batch {
			sent = append(sent, e.Event)
		}
		mu.Unlock()
	}))
	t.Cleanup(posthog.Close)
	client := analyticsClient(t, Options{DataDir: t.TempDir(), PostHogHost: posthog.URL,
		PostHogProjectToken: "phc_test", AnalyticsFirstSend: 10 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	a, err := client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if err != nil || a.GetLevel() != corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC || a.GetPromptAnswered() ||
		!a.GetPersistent() || !a.GetSendingAvailable() || a.GetAnalyticsId() != "" {
		t.Fatalf("first state = %+v, %v", a, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		delivered := len(sent) == 1 && sent[0] == "first_launch"
		mu.Unlock()
		if delivered {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first_launch never reached PostHog")
		}
		time.Sleep(10 * time.Millisecond)
	}

	runs := &corev1.RecordUsageRequest{Event: corev1.UsageEvent_USAGE_EVENT_SCREEN_RUNS_LIST}
	if _, err := client.RecordUsage(ctx, runs); err != nil {
		t.Fatal(err)
	}
	a, _ = client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if counted(a.GetToday(), "screen:runs.list") != 0 {
		t.Fatal("a screen was counted at BASIC")
	}
	a, err = client.SetAnalyticsLevel(ctx, &corev1.SetAnalyticsLevelRequest{Level: corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL, FromPrompt: true})
	if err != nil || !a.GetPromptAnswered() || a.GetAnalyticsId() == "" {
		t.Fatalf("full = %+v, %v", a, err)
	}
	if _, err := client.RecordUsage(ctx, runs); err != nil {
		t.Fatal(err)
	}
	if a, _ = client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{}); counted(a.GetToday(), "screen:runs.list") != 1 || len(a.GetSealed()) != 0 {
		t.Fatalf("today = %+v, sealed = %+v", a.GetToday(), a.GetSealed())
	}
	if _, err := client.RecordUsage(ctx, &corev1.RecordUsageRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no event = %v", err)
	}
	if _, err := client.SetAnalyticsLevel(ctx, &corev1.SetAnalyticsLevelRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no level = %v", err)
	}
}

func TestAnalyticsWithoutADataFolderStayInMemory(t *testing.T) {
	client := analyticsClient(t, Options{PostHogHost: "http://127.0.0.1:1", PostHogProjectToken: "phc_test"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a, err := client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if err != nil || a.GetPersistent() || a.GetSendingAvailable() || len(a.GetSealed()) != 0 {
		t.Fatalf("memory = %+v, %v", a, err)
	}
}

func TestTheCoreCountsTheActionsItDoes(t *testing.T) {
	client := analyticsClient(t, Options{DataDir: t.TempDir()})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	original := "name: CI\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	root := repoWithWorkflows(t, map[string]string{"ci.yml": original})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	save := func() {
		t.Helper()
		current, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := client.SaveWorkflowFile(ctx, &corev1.SaveWorkflowFileRequest{RepositoryId: opened.Repository.Id,
			WorkflowId: ".github/workflows/ci.yml", Content: string(current) + "\n", BaseSha256: scanner.SHA256(current)}); err != nil {
			t.Fatal(err)
		}
	}
	save() // at BASIC: not counted
	if _, err := client.SetAnalyticsLevel(ctx, &corev1.SetAnalyticsLevelRequest{Level: corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL}); err != nil {
		t.Fatal(err)
	}
	save()
	a, err := client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if err != nil || counted(a.GetToday(), "action:editor.save") != 1 {
		t.Fatalf("today = %+v, %v", a.GetToday(), err)
	}
}
