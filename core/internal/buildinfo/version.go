package buildinfo

// Version is set from the release tag with -ldflags at build time.
var Version = "0.1.0-dev"

// Build is the app build this Core ships in (B47): dev, local, alpha, beta
// or release, set from RUNNIR_BUILD with -ldflags. Empty or unknown reads as
// dev, as the app reads a missing RunnirBuild.
var Build = ""

// SupportFolder is the build's folder in Application Support, as the app's
// RunnirBuild.folderName names it: dev and local are apps of their own;
// alpha, beta and release are one app.
func SupportFolder() string {
	switch Build {
	case "local":
		return "Runnir Local"
	case "alpha", "beta", "release":
		return "Runnir"
	default:
		return "Runnir Dev"
	}
}

// PostHogProjectToken and PostHogHost are where analytics go (B21), set
// with -ldflags only in the app builds of a tag (alpha, beta, release). An
// empty token sends no analytics.
var (
	PostHogProjectToken = ""
	PostHogHost         = ""
)

const ProtocolVersion = 1

type Info struct {
	Version         string `json:"version"`
	ProtocolVersion int    `json:"protocolVersion"`
}

func Current() Info {
	return Info{Version: Version, ProtocolVersion: ProtocolVersion}
}
