package licenses

import (
	"strings"
	"testing"
)

func TestTextStartsWithRunnirsLicenseAndNamesTheModules(t *testing.T) {
	text := Text()
	if !strings.HasPrefix(strings.TrimSpace(text), "Apache License") {
		t.Fatalf("text starts with %.40q", strings.TrimSpace(text))
	}
	for _, name := range []string{"Third-party software in Runnir Core", "Go ", "google.golang.org/grpc ", "github.com/rhysd/actionlint ", "modernc.org/sqlite "} {
		if !strings.Contains(text, name) {
			t.Errorf("no %q", name)
		}
	}
}
