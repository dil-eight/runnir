package buildinfo

// Version is set from the release tag with -ldflags at build time.
var Version = "0.1.0-dev"

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
