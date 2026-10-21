package github

import (
	"errors"
	"net"
	"net/url"
	"regexp"
	"strings"
)

// ErrInvalidServer rejects an Enterprise server whose URLs break the rules.
var ErrInvalidServer = errors.New("invalid GitHub server")

// DotComHost is github.com's web host.
const DotComHost = "github.com"

// Server is where a token belongs: github.com (empty ID) or an Enterprise
// server the app registered.
type Server struct {
	// Empty for github.com; a lowercase UUID for an Enterprise server.
	ID string
	// The REST API root, such as "https://github.company.com/api/v3".
	APIURL string
	// The web URL's host, lowercased, without port.
	WebHost string
}

// DotCom is github.com; apiURL overrides https://api.github.com for tests.
func DotCom(apiURL string) Server {
	if apiURL == "" {
		apiURL = defaultBaseURL
	}
	return Server{APIURL: apiURL, WebHost: DotComHost}
}

var (
	serverID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	hostName = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$`)
)

// Validate checks an Enterprise server: a UUID id; an https API URL (http
// only for a loopback host) with a host and no user info, query or
// fragment; a web host that is a lowercase host name other than github.com.
// github.com itself is always valid.
func (s Server) Validate() error {
	if s.ID == "" {
		return nil
	}
	if !serverID.MatchString(s.ID) {
		return ErrInvalidServer
	}
	api, err := url.Parse(s.APIURL)
	if err != nil || api.Host == "" || api.User != nil || api.RawQuery != "" || api.Fragment != "" || api.Opaque != "" {
		return ErrInvalidServer
	}
	switch api.Scheme {
	case "https":
	case "http":
		if !isLoopback(api.Hostname()) {
			return ErrInvalidServer
		}
	default:
		return ErrInvalidServer
	}
	if s.WebHost != NormalizeHost(s.WebHost) || s.WebHost == DotComHost || !hostName.MatchString(s.WebHost) {
		return ErrInvalidServer
	}
	return nil
}

// NormalizeHost lowercases a host and drops its port.
func NormalizeHost(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return strings.ToLower(strings.Trim(host, "[]"))
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
