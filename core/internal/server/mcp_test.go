//go:build !windows

package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// mcpRig starts a Core with a short data folder and returns the app's
// client on the main socket and a client of the MCP socket.
func mcpRig(t *testing.T) (corev1.RunnirCoreClient, corev1.McpBridgeClient, string, context.Context) {
	t.Helper()
	data, err := os.MkdirTemp("/tmp", "rd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(data) })
	main, ctx := servedWith(t, Options{DataDir: data})
	mcpPath := filepath.Join(data, McpSocketName)
	waitForSocket(t, mcpPath, make(chan error, 1))
	conn, err := grpc.NewClient("unix://"+mcpPath, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return main, corev1.NewMcpBridgeClient(conn), mcpPath, ctx
}

// fakeApp answers the Core's MCP requests on the main socket as answer says.
func fakeApp(t *testing.T, ctx context.Context, client corev1.RunnirCoreClient, answer func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest) {
	t.Helper()
	appCtx, cancel := context.WithCancel(ctx)
	t.Cleanup(cancel)
	stream, err := client.SubscribeMcpRequests(appCtx, &corev1.SubscribeMcpRequestsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	subscribed := make(chan struct{})
	go func() {
		close(subscribed)
		for {
			request, err := stream.Recv()
			if err != nil {
				return
			}
			a := answer(request)
			a.Id = request.Id
			_, _ = client.AnswerMcpRequest(appCtx, a)
		}
	}()
	<-subscribed
	// The subscription is registered once the server has the stream; give
	// it a moment, as the stream's first message is the first request.
	time.Sleep(100 * time.Millisecond)
}

func TestMcpCallsReachTheAppAndItsAnswersComeBack(t *testing.T) {
	main, bridge, mcpPath, ctx := mcpRig(t)
	fakeApp(t, ctx, main, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		if r.Tool == corev1.McpTool_MCP_TOOL_LIST_VALUE_SETS {
			return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Sets{Sets: &corev1.McpValueSets{
				Workspace: "r", Sets: []*corev1.McpValueSet{{Name: "Repository"}}}}}
		}
		if r.Set != "production" {
			return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Refusal{Refusal: "r has no set named " + r.Set + "."}}
		}
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Saved{Saved: &corev1.McpSavedValues{
			Workspace: "r", Set: r.Set, Secrets: []string{r.Secrets[0].Name}}}}
	})

	call := func(client, tool, args string) *corev1.McpBridgeCallToolResponse {
		t.Helper()
		out, err := bridge.CallTool(ctx, &corev1.McpBridgeCallToolRequest{Client: client, Tool: tool, ArgumentsJson: args})
		if err != nil {
			t.Fatalf("%s: %v", tool, err)
		}
		return out
	}
	sets := call("codex", "runnir_list_value_sets", `{"repository":"/r"}`)
	if sets.IsError || !strings.Contains(sets.StructuredJson, `"workspace":"r"`) || !strings.Contains(sets.Text, `"Repository"`) {
		t.Fatalf("sets = %v", sets)
	}
	saved := call("codex", "runnir_set_values", `{"repository":"/r","set":"production","secrets":{"API_KEY":"s3cr3t"}}`)
	if saved.IsError || !strings.Contains(saved.Text, "Saved in r › production") || strings.Contains(saved.Text, "s3cr3t") {
		t.Fatalf("saved = %v", saved)
	}
	refused := call("codex", "runnir_set_values", `{"repository":"/r","set":"staging","secrets":{"API_KEY":"s3cr3t"}}`)
	if !refused.IsError || !strings.Contains(refused.Text, "no set named staging") {
		t.Fatalf("refusal = %v", refused)
	}
	checked := call("codex", "runnir_set_values", `{"repository":"/r","set":"production","secrets":{"GITHUB_SHA":"x"}}`)
	if !checked.IsError || !strings.Contains(checked.Text, "GITHUB_") {
		t.Fatalf("check = %v", checked)
	}

	info, err := os.Stat(mcpPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mcp.sock = %v, %v", info, err)
	}
}

func TestTheMcpSocketServesNothingElse(t *testing.T) {
	_, _, mcpPath, ctx := mcpRig(t)
	conn, err := grpc.NewClient("unix://"+mcpPath, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, err = corev1.NewRunnirCoreClient(conn).HealthCheck(ctx, &corev1.HealthCheckRequest{})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("HealthCheck on mcp.sock = %v", err)
	}
}

func TestMcpCallsWithoutTheAppSaySo(t *testing.T) {
	_, bridge, _, ctx := mcpRig(t)
	out, err := bridge.CallTool(ctx, &corev1.McpBridgeCallToolRequest{Tool: "runnir_list_workspaces", ArgumentsJson: "{}"})
	if err != nil || !out.IsError || !strings.Contains(out.Text, "not running") {
		t.Fatalf("out = %v, %v", out, err)
	}
}

func TestAnAnswerToNoRequestIsNotFound(t *testing.T) {
	main, _, _, ctx := mcpRig(t)
	_, err := main.AnswerMcpRequest(ctx, &corev1.AnswerMcpRequestRequest{Id: "mcp_nope",
		Answer: &corev1.AnswerMcpRequestRequest_Refusal{Refusal: "x"}})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("err = %v", err)
	}
}

func TestWithoutADataFolderThereIsNoMcpSocket(t *testing.T) {
	path := socketPath(t)
	_, _ = serving(t, path, startWith(t, path, Options{}))
	if _, err := os.Stat(filepath.Join(filepath.Dir(path), McpSocketName)); !os.IsNotExist(err) {
		t.Fatalf("mcp.sock: %v", err)
	}
}

// A tool that the Core runs itself reaches the app only to open the
// workspace, then reads the Core's own repository.
func TestMcpToolsReadTheCoresOwnRepositories(t *testing.T) {
	main, bridge, _, ctx := mcpRig(t)
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".github", "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".github", "workflows", "ci.yml"), []byte("name: CI\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	opened, err := main.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	fakeApp(t, ctx, main, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Workspace{Workspace: &corev1.McpOpenedWorkspace{
			Workspace: &corev1.McpWorkspace{Name: "repo", Path: repo}, RepositoryId: opened.GetRepository().GetId()}}}
	})
	out, err := bridge.CallTool(ctx, &corev1.McpBridgeCallToolRequest{Tool: "runnir_get_workflow", ArgumentsJson: `{"repository":"repo","workflow":"CI"}`})
	if err != nil || out.IsError || !strings.Contains(out.StructuredJson, `"path":".github/workflows/ci.yml"`) || !strings.Contains(out.StructuredJson, "echo hi") {
		t.Fatalf("out = %v, %v", out, err)
	}
	out, err = bridge.CallTool(ctx, &corev1.McpBridgeCallToolRequest{Tool: "runnir_list_local_runs", ArgumentsJson: `{"repository":"repo"}`})
	if err != nil || out.IsError || !strings.Contains(out.StructuredJson, `"runs":[]`) {
		t.Fatalf("out = %v, %v", out, err)
	}
}
