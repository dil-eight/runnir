package scanner

import (
	"strings"

	"github.com/rhysd/actionlint"

	"runnir/core/internal/repository"
)

// manualTrigger reads a job's if: the job is started by hand when one of the
// condition's top-level && terms is github.event_name == 'workflow_dispatch'.
// It also returns the inputs other == terms fix (github.event.inputs.X or
// inputs.X against a string or boolean), by lower-case name.
func manualTrigger(condition string) (map[string]string, bool) {
	source := strings.TrimSpace(condition)
	if inner, ok := strings.CutPrefix(source, "${{"); ok {
		if source, ok = strings.CutSuffix(strings.TrimSpace(inner), "}}"); !ok {
			return nil, false
		}
	}
	expr, err := actionlint.NewExprParser().Parse(actionlint.NewExprLexer(source + "}}"))
	if err != nil {
		return nil, false
	}
	dispatch := false
	inputs := map[string]string{}
	var terms func(actionlint.ExprNode)
	terms = func(n actionlint.ExprNode) {
		if and, ok := n.(*actionlint.LogicalOpNode); ok && and.Kind == actionlint.LogicalOpNodeKindAnd {
			terms(and.Left)
			terms(and.Right)
			return
		}
		compare, ok := n.(*actionlint.CompareOpNode)
		if !ok || compare.Kind != actionlint.CompareOpNodeKindEq {
			return
		}
		for _, sides := range [][2]actionlint.ExprNode{{compare.Left, compare.Right}, {compare.Right, compare.Left}} {
			value, ok := literal(sides[1])
			if !ok {
				continue
			}
			path := propertyPath(sides[0])
			switch {
			// GitHub compares strings ignoring case.
			case path == "github.event_name" && strings.EqualFold(value, "workflow_dispatch"):
				dispatch = true
			case strings.HasPrefix(path, "github.event.inputs."):
				inputs[strings.TrimPrefix(path, "github.event.inputs.")] = value
			case strings.HasPrefix(path, "inputs."):
				inputs[strings.TrimPrefix(path, "inputs.")] = value
			}
		}
	}
	terms(expr)
	return inputs, dispatch
}

// propertyPath spells a property access as dotted, lower-case names, or "".
func propertyPath(n actionlint.ExprNode) string {
	switch n := n.(type) {
	case *actionlint.VariableNode:
		return n.Name
	case *actionlint.ObjectDerefNode:
		if base := propertyPath(n.Receiver); base != "" {
			return base + "." + n.Property
		}
	case *actionlint.IndexAccessNode:
		if index, ok := n.Index.(*actionlint.StringNode); ok {
			if base := propertyPath(n.Operand); base != "" {
				return base + "." + strings.ToLower(index.Value)
			}
		}
	}
	return ""
}

func literal(n actionlint.ExprNode) (string, bool) {
	switch n := n.(type) {
	case *actionlint.StringNode:
		return n.Value, true
	case *actionlint.BoolNode:
		if n.Value {
			return "true", true
		}
		return "false", true
	}
	return "", false
}

// markManualJobs marks the jobs started by hand, once the workflow's
// triggers and dispatch inputs are known: those whose if requires a
// workflow_dispatch run, or, in a workflow that starts only by hand and has
// none of those, the jobs that need no other, since starting the workflow
// starts them. A job whose start would leave a required input without a
// value is not marked. Input names take the spelling the workflow declares.
func markManualJobs(workflow *repository.Workflow, conditions map[int]string) {
	dispatchable, onlyDispatch := false, len(workflow.Triggers) > 0
	for _, trigger := range workflow.Triggers {
		dispatchable = dispatchable || trigger == "workflow_dispatch"
		onlyDispatch = onlyDispatch && trigger == "workflow_dispatch"
	}
	if !dispatchable {
		return
	}
	started := map[int]map[string]string{}
	for index, condition := range conditions {
		if inputs, ok := manualTrigger(condition); ok && index < len(workflow.Jobs) {
			started[index] = inputs
		}
	}
	if len(started) == 0 && onlyDispatch {
		for index, job := range workflow.Jobs {
			if len(job.Needs) == 0 {
				// The == terms of its if still fix inputs; no if fixes none.
				started[index], _ = manualTrigger(conditions[index])
			}
		}
	}
	for index, inputs := range started {
		named := map[string]string{}
		for name, value := range inputs {
			for _, declared := range workflow.DispatchInputs {
				if strings.EqualFold(declared.Name, name) {
					name = declared.Name
					break
				}
			}
			named[name] = value
		}
		if missesRequiredInput(workflow.DispatchInputs, named) {
			continue
		}
		workflow.Jobs[index].Manual = true
		workflow.Jobs[index].ManualInputs = named
	}
}

// missesRequiredInput: a required input has no default and the start does not
// set it, so GitHub would refuse the start.
func missesRequiredInput(declared []repository.DispatchInput, inputs map[string]string) bool {
	for _, input := range declared {
		if input.Required && input.Default == "" && inputs[input.Name] == "" {
			return true
		}
	}
	return false
}
