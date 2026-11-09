package localrun

import (
	"bytes"
	"errors"
	"strings"

	"go.yaml.in/yaml/v3"

	"runnir/core/internal/yamlnode"
)

// Trim returns a workflow file with only the jobs in keep (lower-cased
// keys). act runs one job or all of a file's, so a lane runs this copy
// instead of the file. A file whose jobs are all kept comes back as it is.
func Trim(source []byte, keep map[string]bool) ([]byte, error) {
	var document yaml.Node
	if err := yaml.Unmarshal(source, &document); err != nil {
		return nil, err
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return nil, errors.New("not a workflow document")
	}
	root := yamlnode.Resolve(document.Content[0])
	if root.Kind != yaml.MappingNode {
		return nil, errors.New("not a workflow document")
	}
	var jobs *yaml.Node
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value == "jobs" {
			jobs = yamlnode.Resolve(root.Content[i+1])
		}
	}
	if jobs == nil || jobs.Kind != yaml.MappingNode {
		return nil, errors.New("the workflow has no jobs")
	}
	var kept []*yaml.Node
	for i := 0; i+1 < len(jobs.Content); i += 2 {
		if keep[strings.ToLower(jobs.Content[i].Value)] {
			kept = append(kept, jobs.Content[i], jobs.Content[i+1])
		}
	}
	if len(kept) == len(jobs.Content) {
		return append([]byte(nil), source...), nil
	}
	if len(kept) == 0 {
		return nil, errors.New("no job is kept")
	}
	jobs.Content = kept
	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	if err := encoder.Encode(&document); err != nil {
		return nil, err
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
