package buildinfo

import "testing"

func TestEachBuildHasTheAppsSupportFolder(t *testing.T) {
	defer func(build string) { Build = build }(Build)
	for build, folder := range map[string]string{
		"": "Runnir Dev", "dev": "Runnir Dev", "bogus": "Runnir Dev",
		"local": "Runnir Local", "alpha": "Runnir", "beta": "Runnir", "release": "Runnir",
	} {
		Build = build
		if got := SupportFolder(); got != folder {
			t.Errorf("%q: %q, want %q", build, got, folder)
		}
	}
}
