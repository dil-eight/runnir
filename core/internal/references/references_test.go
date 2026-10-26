package references

import (
	"slices"
	"testing"
)

func TestFindNamesEveryForm(t *testing.T) {
	source := []byte(`
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    if: vars.ENABLED == 'true' && secrets.GATE != ''
    env:
      REGION: ${{ vars.region }}
    steps:
      - run: echo ${{ secrets.NPM_TOKEN }} ${{ secrets['Deploy_Key'] }} ${{ vars["STAGE"] }}
      - run: echo ${{ secrets.npm_token }} ${{ github.token }}
      # ${{ secrets.IN_COMMENT }}
      - id: vars
        run: echo "${{ steps.vars.outputs.sha }} ${{ needs.secrets.result }} ${{ myvars.NOT_A_VAR }}"
`)
	names := Find(source)
	if want := []string{"DEPLOY_KEY", "GATE", "NPM_TOKEN"}; !slices.Equal(names.Secrets, want) {
		t.Fatalf("secrets = %v, want %v", names.Secrets, want)
	}
	if want := []string{"ENABLED", "REGION", "STAGE"}; !slices.Equal(names.Variables, want) {
		t.Fatalf("variables = %v, want %v", names.Variables, want)
	}
	if names.UnnamedSecrets {
		t.Fatal("unnamed secrets reported for named ones")
	}
}

func TestFindReportsSecretsReadAsAWhole(t *testing.T) {
	for _, source := range []string{
		"steps:\n  - run: echo '${{ toJSON(secrets) }}'\n",
		"steps:\n  - run: echo '${{ tojson( secrets ) }}'\n",
		"jobs:\n  call:\n    uses: ./.github/workflows/r.yml\n    secrets: inherit\n",
		"steps:\n  - run: echo ${{ secrets[matrix.name] }}\n",
	} {
		if !Find([]byte(source)).UnnamedSecrets {
			t.Errorf("not reported: %q", source)
		}
	}
}

func TestFindReadsTextThatIsNotYAML(t *testing.T) {
	names := Find([]byte("name: [\n  ${{ secrets.STILL_FOUND }} ${{ steps.vars.outputs.x }}\n# ${{ secrets.COMMENTED }}\n"))
	if !slices.Equal(names.Secrets, []string{"STILL_FOUND"}) || len(names.Variables) != 0 {
		t.Fatalf("names = %+v", names)
	}
}

func TestFindNothing(t *testing.T) {
	names := Find([]byte("on: push\njobs: {}\n"))
	if len(names.Secrets) != 0 || len(names.Variables) != 0 || names.UnnamedSecrets {
		t.Fatalf("names = %+v", names)
	}
}
