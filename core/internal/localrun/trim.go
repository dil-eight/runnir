package localrun

import (
	"bytes"
	"errors"
	"strings"

	"go.yaml.in/yaml/v3"

	"runnir/core/internal/yamlnode"
)

// maxExpandedNodes bounds the nodes Trim copies in place of aliases.
const maxExpandedNodes = 100_000

// Trim returns a workflow file with only the jobs in keep (lower-cased
// keys). act runs one job or all of a file's, so a lane runs this copy
// instead of the file. A file whose jobs are all kept comes back as it is.
// An alias whose anchor was in a job left out gets a copy of what it named,
// and a kept job loses its needs on jobs left out: a lane in the macOS
// sandbox runs those in an earlier act (Parts).
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
	dropped := map[*yaml.Node]bool{}
	for i := 0; i+1 < len(jobs.Content); i += 2 {
		if keep[strings.ToLower(jobs.Content[i].Value)] {
			kept = append(kept, jobs.Content[i], jobs.Content[i+1])
		} else {
			mark(jobs.Content[i], dropped)
			mark(jobs.Content[i+1], dropped)
		}
	}
	if len(kept) == len(jobs.Content) {
		return append([]byte(nil), source...), nil
	}
	if len(kept) == 0 {
		return nil, errors.New("no job is kept")
	}
	for i := 1; i < len(kept); i += 2 {
		job, err := withoutDroppedNeeds(kept[i], keep)
		if err != nil {
			return nil, err
		}
		kept[i] = job
	}
	jobs.Content = kept
	budget := maxExpandedNodes
	if err := expandDropped(&document, dropped, &budget); err != nil {
		return nil, err
	}
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

// withoutDroppedNeeds is a kept job without its needs on jobs left out, or
// the job itself when it has none.
func withoutDroppedNeeds(job *yaml.Node, keep map[string]bool) (*yaml.Node, error) {
	var body map[string]any
	if err := job.Decode(&body); err != nil {
		return nil, err
	}
	var needs []any
	switch value := body["needs"].(type) {
	case string:
		needs = []any{value}
	case []any:
		needs = value
	default:
		return job, nil
	}
	var kept []any
	for _, need := range needs {
		if name, ok := need.(string); ok && keep[strings.ToLower(name)] {
			kept = append(kept, name)
		}
	}
	if len(kept) == len(needs) {
		return job, nil
	}
	if len(kept) == 0 {
		delete(body, "needs")
	} else {
		body["needs"] = kept
	}
	var out yaml.Node
	if err := out.Encode(body); err != nil {
		return nil, err
	}
	return &out, nil
}

// mark adds a node and everything in it, but not what its aliases name.
func mark(node *yaml.Node, set map[*yaml.Node]bool) {
	set[node] = true
	for _, child := range node.Content {
		mark(child, set)
	}
}

// expandDropped replaces each alias under node that names a node in dropped
// with a copy of that node.
func expandDropped(node *yaml.Node, dropped map[*yaml.Node]bool, budget *int) error {
	for i, child := range node.Content {
		if child.Kind == yaml.AliasNode {
			if child.Alias != nil && dropped[child.Alias] {
				copied, err := expandedCopy(child.Alias, dropped, budget)
				if err != nil {
					return err
				}
				node.Content[i] = copied
			}
			continue
		}
		if err := expandDropped(child, dropped, budget); err != nil {
			return err
		}
	}
	return nil
}

// expandedCopy copies a node without its anchor, expanding the aliases in
// it that name a node in dropped.
func expandedCopy(node *yaml.Node, dropped map[*yaml.Node]bool, budget *int) (*yaml.Node, error) {
	if *budget--; *budget < 0 {
		return nil, errors.New("the file's aliases expand too far")
	}
	if node.Kind == yaml.AliasNode {
		if node.Alias != nil && dropped[node.Alias] {
			return expandedCopy(node.Alias, dropped, budget)
		}
		copied := *node
		return &copied, nil
	}
	copied := *node
	copied.Anchor = ""
	copied.Content = make([]*yaml.Node, len(node.Content))
	for i, child := range node.Content {
		var err error
		if copied.Content[i], err = expandedCopy(child, dropped, budget); err != nil {
			return nil, err
		}
	}
	return &copied, nil
}
