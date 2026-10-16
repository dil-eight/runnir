package buildinfo

// Version is set from the release tag with -ldflags at build time.
var Version = "0.1.0-dev"

const ProtocolVersion = 1

type Info struct {
	Version         string `json:"version"`
	ProtocolVersion int    `json:"protocolVersion"`
}

func Current() Info {
	return Info{Version: Version, ProtocolVersion: ProtocolVersion}
}
