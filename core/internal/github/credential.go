// Package github holds the Core's GitHub access: the user's token, kept only
// in memory, and the API client that uses it.
package github

import (
	"errors"
	"strings"
	"sync"
)

// ErrInvalidToken rejects values that cannot be a GitHub token.
var ErrInvalidToken = errors.New("invalid GitHub token")

// Credential holds the signed-in user's token in memory only. It is safe for
// concurrent use and has no way to persist or print the token.
type Credential struct {
	mu    sync.RWMutex
	token string
}

// Set replaces the token. GitHub tokens are short printable strings without
// whitespace; anything else is refused.
func (c *Credential) Set(token string) error {
	if token == "" || len(token) > 255 || strings.ContainsFunc(token, func(r rune) bool { return r <= ' ' || r > '~' }) {
		return ErrInvalidToken
	}
	c.mu.Lock()
	c.token = token
	c.mu.Unlock()
	return nil
}

// Clear forgets the token.
func (c *Credential) Clear() {
	c.mu.Lock()
	c.token = ""
	c.mu.Unlock()
}

// Token returns the token and whether one is set.
func (c *Credential) Token() (string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.token, c.token != ""
}

// String never reveals the token, in case a Credential reaches a log line.
func (c *Credential) String() string {
	if _, ok := c.Token(); ok {
		return "github.Credential(set)"
	}
	return "github.Credential(empty)"
}
