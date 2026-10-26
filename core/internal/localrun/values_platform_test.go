package localrun

import (
	"path/filepath"
	"testing"
)

func TestValueFilesWithoutPipesAreTheEmptyFile(t *testing.T) {
	if got := valueFileFor(false, "/scratch", SecretsFile); got != filepath.Join("/scratch", "empty") {
		t.Fatalf("without pipes = %q", got)
	}
	if got := valueFileFor(true, "/scratch", VarsFile); got != filepath.Join("/scratch", VarsFile) {
		t.Fatalf("with pipes = %q", got)
	}
}
