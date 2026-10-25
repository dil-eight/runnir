package localrun

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The names act's --secret-file and --var-file get in the run's scratch
// folder: symbolic links to the pipes act inherits as fd 3 and 4. act reads
// a file whose name ends in .yaml once, as YAML, and JSON is YAML.
const (
	SecretsFile = "secrets.yaml"
	VarsFile    = "vars.yaml"
)

// valueFeed writes one JSON object into a pipe that act reads as a file.
type valueFeed struct {
	read, write *os.File
	data        []byte
	done        chan struct{}
}

// attachValues creates the pipes and links and adds the read ends to cmd.
// GITHUB_TOKEN is always among the secrets, so act never asks the gh CLI
// for one.
func attachValues(cmd *exec.Cmd, scratch string, spec *Spec) ([]*valueFeed, error) {
	secrets := map[string]string{"GITHUB_TOKEN": ""}
	for name, value := range spec.Secrets {
		secrets[name] = value
	}
	variables := map[string]string{}
	for name, value := range spec.Variables {
		variables[name] = value
	}
	var feeds []*valueFeed
	for i, item := range []struct {
		file   string
		values map[string]string
	}{{SecretsFile, secrets}, {VarsFile, variables}} {
		data, err := json.Marshal(item.values)
		if err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		read, write, err := os.Pipe()
		if err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		feeds = append(feeds, &valueFeed{read: read, write: write, data: data, done: make(chan struct{})})
		if err := os.Symlink("/dev/fd/"+strconv.Itoa(3+i), filepath.Join(scratch, item.file)); err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		cmd.ExtraFiles = append(cmd.ExtraFiles, read)
	}
	return feeds, nil
}

// send runs once act has started: the parent's copy of the read end closes
// and the values are written. A write error means act exited without
// reading them; its own failure is what the user sees.
func (f *valueFeed) send() {
	_ = f.read.Close()
	go func() {
		defer close(f.done)
		_, _ = f.write.Write(f.data)
		_ = f.write.Close()
		f.data = nil
	}()
}

// finish runs once act has exited: closing the write end ends a write still
// blocked on a full pipe, whose read end a process act left behind may hold.
func (f *valueFeed) finish() {
	_ = f.write.Close()
	<-f.done
}

func closeFeeds(feeds []*valueFeed) {
	for _, f := range feeds {
		_ = f.read.Close()
		_ = f.write.Close()
	}
}

// masksFor lists what to hide in a run's output: each secret value, and each
// line of a multi-line one of at least 4 characters, longest first. Short
// lines such as "{" would hide unrelated output; the whole value is always
// hidden.
func masksFor(secrets map[string]string) []string {
	seen := map[string]bool{}
	var masks []string
	add := func(text string) {
		if text != "" && !seen[text] {
			seen[text] = true
			masks = append(masks, text)
		}
	}
	for _, value := range secrets {
		add(value)
		if strings.Contains(value, "\n") {
			for _, line := range strings.Split(value, "\n") {
				if line = strings.TrimSpace(line); len(line) >= 4 {
					add(line)
				}
			}
		}
	}
	sort.Slice(masks, func(i, j int) bool {
		if len(masks[i]) != len(masks[j]) {
			return len(masks[i]) > len(masks[j])
		}
		return masks[i] < masks[j]
	})
	return masks
}

func mask(text string, masks []string) string {
	for _, m := range masks {
		text = strings.ReplaceAll(text, m, "***")
	}
	return text
}
