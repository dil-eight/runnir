package mcp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The Runnir plugin starts the same server for Claude Code and for Codex
// (plugins/runnir): Runnir in /Applications, with no --data-dir, so the
// command is the same for every user.
func TestThePluginStartsTheSameServerForBothClients(t *testing.T) {
	type server struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	read := func(path string, into any) {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join("..", "..", "..", "plugins", "runnir", path))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, into); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
	}
	var claude struct {
		Version    string            `json:"version"`
		McpServers map[string]server `json:"mcpServers"`
	}
	var codex struct {
		Version    string `json:"version"`
		McpServers string `json:"mcpServers"`
	}
	var codexServers struct {
		McpServers map[string]server `json:"mcpServers"`
	}
	read(".claude-plugin/plugin.json", &claude)
	read(".codex-plugin/plugin.json", &codex)
	read(codex.McpServers, &codexServers)

	want := map[string]server{"runnir": {Command: "/Applications/Runnir.app/Contents/Helpers/runnir-core", Args: []string{"mcp"}}}
	if !reflect.DeepEqual(claude.McpServers, want) || !reflect.DeepEqual(codexServers.McpServers, want) {
		t.Fatalf("claude = %v, codex = %v", claude.McpServers, codexServers.McpServers)
	}
	if claude.Version == "" || claude.Version != codex.Version {
		t.Fatalf("versions: claude %q, codex %q", claude.Version, codex.Version)
	}
}
