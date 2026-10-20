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
	Lines           []string `json:"lines"`
	Stderr          []string `json:"stderr"`
	Exit            int      `json:"exit"`
	WaitForSignal   bool     `json:"waitForSignal"`
	IgnoreInterrupt bool     `json:"ignoreInterrupt"`
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
	var s script
	if data, err := os.ReadFile(filepath.Join(dir, "act.json")); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt)
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
	os.Exit(s.Exit)
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
