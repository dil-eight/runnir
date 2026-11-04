package localrun

import (
	"slices"
	"testing"

	"runnir/core/internal/repository"
)

func TestEnvironmentsAddGitHubsOnlyForAJobAnExpressionPlaces(t *testing.T) {
	named := []repository.Workflow{{Jobs: []repository.Job{{ID: "build"}, {ID: "seed", Environment: "Staging"}}}}
	asked := false
	onGitHub := func() []string { asked = true; return []string{"production", "staging", "github-pages"} }
	if got := Environments(named, onGitHub); !slices.Equal(got, []string{"Staging"}) || asked {
		t.Fatalf("named = %v, asked GitHub = %v", got, asked)
	}

	picked := append(named, repository.Workflow{Jobs: []repository.Job{{ID: "deploy", EnvironmentExpression: true}}})
	if got := Environments(picked, onGitHub); !slices.Equal(got, []string{"github-pages", "production", "Staging"}) {
		t.Fatalf("picked = %v", got)
	}
	if got := Environments(picked, func() []string { return nil }); !slices.Equal(got, []string{"Staging"}) {
		t.Fatalf("without GitHub = %v", got)
	}
}
