// Package github holds the Core's GitHub access: the user's token, kept only
// in memory, and the API client that uses it.
package github

import (
	"errors"
	"strings"
	"sync"
	"sync/atomic"
)

// ErrInvalidToken rejects values that cannot be a GitHub token.
var ErrInvalidToken = errors.New("invalid GitHub token")

// changes numbers every change of any credential, so no two credentials
// share a generation or a sign-in.
var changes atomic.Uint64

// Credential holds the signed-in user's token in memory only. It is safe for
// concurrent use and has no way to persist or print the token.
type Credential struct {
	mu    sync.RWMutex
	token string
	// generation is the number of the token's latest change; signIn that
	// of the change that set a token where there was none.
	generation, signIn uint64
}

// Set replaces the token. GitHub tokens are short printable strings without
// whitespace; anything else is refused.
func (c *Credential) Set(token string) error {
	if token == "" || len(token) > 255 || strings.ContainsFunc(token, func(r rune) bool { return r <= ' ' || r > '~' }) {
		return ErrInvalidToken
	}
	c.mu.Lock()
	if c.token != token {
		c.generation = changes.Add(1)
		if c.token == "" {
			c.signIn = c.generation
		}
		c.token = token
	}
	c.mu.Unlock()
	return nil
}

// Clear forgets the token.
func (c *Credential) Clear() {
	c.mu.Lock()
	if c.token != "" {
		c.token = ""
		c.generation = changes.Add(1)
	}
	c.mu.Unlock()
}

// Generation changes whenever the token is set to another or cleared, so
// what was read with a token can be kept until then. A later change has a
// higher number.
func (c *Credential) Generation() uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}

// SignIn changes when a token is set where there was none: at the first
// sign-in and after a sign-out, not when a token replaces another (a
// refreshed token). What was read for a sign-in can be shown until then.
func (c *Credential) SignIn() uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.signIn
}

// Token returns the token and whether one is set.
func (c *Credential) Token() (string, bool) {
	token, _ := c.current()
	return token, token != ""
}

// current returns the token with its generation, read together.
func (c *Credential) current() (string, uint64) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.token, c.generation
}

// String never reveals the token, in case a Credential reaches a log line.
func (c *Credential) String() string {
	if _, ok := c.Token(); ok {
		return "github.Credential(set)"
	}
	return "github.Credential(empty)"
}
