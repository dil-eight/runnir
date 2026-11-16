// Command fake stands in for act and docker in the runner tests. It reads
// what to do from files next to its executable and records how it was
// started there.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"
)

type script struct {
	Lines  []string `json:"lines"`
	Stderr []string `json:"stderr"`
	Exit   int      `json:"exit"`
	// Exits, when set, is the exit code of each run of act in turn.
	Exits []int `json:"exits"`
	// RunLines, when set, are the lines of each run of act in turn, in
	// place of Lines.
	RunLines        [][]string `json:"runLines"`
	WaitForSignal   bool       `json:"waitForSignal"`
	IgnoreInterrupt bool       `json:"ignoreInterrupt"`
	// CopyValueFiles records what the --secret-file, --var-file,
	// --workflows and --eventpath paths hold, in act.files, a line per run.
	CopyValueFiles bool `json:"copyValueFiles"`
}

type invocation struct {
	Args []string `json:"args"`
	Env  []string `json:"env"`
	Dir  string   `json:"dir"`
}

func main() {
	executable, _ := os.Executable()
	dir := filepath.Dir(executable)
	name := strings.TrimSuffix(filepath.Base(executable), ".exe")
	cwd, _ := os.Getwd()
	record, _ := json.Marshal(invocation{Args: os.Args[1:], Env: os.Environ(), Dir: cwd})
	appendFile(filepath.Join(dir, name+".invocations"), string(record)+"\n")

	if name == "docker" {
		docker(dir)
		return
	}
	if name == "sandbox-exec" {
		// sandbox-exec -f PROFILE COMMAND ARGS...: keep the profile, then
		// become the command, as the real one does.
		if len(os.Args) > 3 {
			profile, _ := os.ReadFile(os.Args[2])
			appendFile(filepath.Join(dir, "sandbox.profile"), string(profile))
			become(os.Args[3], os.Args[3:])
		}
		os.Exit(71)
	}
	var s script
	if data, err := os.ReadFile(filepath.Join(dir, "act.json")); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	if s.CopyValueFiles {
		files := map[string]string{}
		for _, arg := range os.Args[1:] {
			for _, flag := range []string{"--secret-file=", "--var-file=", "--workflows=", "--eventpath="} {
				if path, ok := strings.CutPrefix(arg, flag); ok {
					data, err := os.ReadFile(path)
					if err != nil {
						data = []byte("error: " + err.Error())
					}
					files[flag] = string(data)
				}
			}
		}
		encoded, _ := json.Marshal(files)
		appendFile(filepath.Join(dir, "act.files"), string(encoded)+"\n")
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt)
	if runs := countLines(filepath.Join(dir, name+".invocations")); runs > 0 && runs <= len(s.RunLines) {
		s.Lines = s.RunLines[runs-1]
	}
	for _, line := range s.Lines {
		fmt.Println(line)
	}
	for _, line := range s.Stderr {
		fmt.Fprintln(os.Stderr, line)
	}
	if s.WaitForSignal {
		for {
			<-signals
			if !s.IgnoreInterrupt {
				fmt.Println(`{"level":"info","msg":"interrupted"}`)
				os.Exit(130)
			}
			time.Sleep(time.Millisecond)
		}
	}
	if runs := countLines(filepath.Join(dir, name+".invocations")); runs > 0 && runs <= len(s.Exits) {
		os.Exit(s.Exits[runs-1])
	}
	os.Exit(s.Exit)
}

func countLines(path string) int {
	data, _ := os.ReadFile(path)
	return strings.Count(string(data), "\n")
}

func docker(dir string) {
	switch {
	case len(os.Args) > 1 && os.Args[1] == "ps":
		data, _ := os.ReadFile(filepath.Join(dir, "containers"))
		fmt.Print(string(data))
	case len(os.Args) > 1 && os.Args[1] == "rm":
		if _, err := os.Stat(filepath.Join(dir, "rm-fails")); err == nil {
			os.Exit(1)
		}
	}
}

func appendFile(path, text string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(text)
}
