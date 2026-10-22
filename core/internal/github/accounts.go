package github

import (
	"errors"
	"sync"
)

// MaxEnterpriseServers bounds the Enterprise servers the Core holds.
const MaxEnterpriseServers = 10

// ErrTooManyServers refuses an Enterprise server past MaxEnterpriseServers.
var ErrTooManyServers = errors.New("too many GitHub servers")

// Account is one server with its own token and client; a token is never
// used for another server.
type Account struct {
	Server     Server
	Credential *Credential
	Client     *Client
}

// Accounts holds github.com, always, and the Enterprise servers the app
// signed in to. Safe for concurrent use.
type Accounts struct {
	mu      sync.RWMutex
	byID    map[string]*Account
	version string
}

// NewAccounts starts with github.com and no token; dotComAPIURL overrides
// https://api.github.com for tests.
func NewAccounts(dotComAPIURL, version string) *Accounts {
	a := &Accounts{byID: map[string]*Account{}, version: version}
	a.byID[""] = a.newAccount(DotCom(dotComAPIURL))
	return a
}

func (a *Accounts) newAccount(server Server) *Account {
	credential := &Credential{}
	return &Account{Server: server, Credential: credential, Client: NewClient(credential, server.APIURL, a.version)}
}

// Get returns the account for a server id; "" is github.com.
func (a *Accounts) Get(id string) (*Account, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	account, ok := a.byID[id]
	return account, ok
}

// ForHost finds the account whose web host is host, ignoring case and port.
func (a *Accounts) ForHost(host string) (*Account, bool) {
	host = NormalizeHost(host)
	if host == "" {
		return nil, false
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	for _, account := range a.byID {
		if account.Server.WebHost == host {
			return account, true
		}
	}
	return nil, false
}

// Set gives a server its token. github.com keeps its own URLs whatever the
// request says; an Enterprise server is added, or replaced when its URLs
// changed, so a token never reaches a URL it was not set for. A refused
// token leaves the accounts as they were.
func (a *Accounts) Set(server Server, token string) (*Account, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if server.ID == "" {
		dotcom := a.byID[""]
		return dotcom, dotcom.Credential.Set(token)
	}
	if err := server.Validate(); err != nil {
		return nil, err
	}
	others := 0
	for id, account := range a.byID {
		if id == server.ID {
			continue
		}
		if account.Server.WebHost == server.WebHost {
			return nil, ErrInvalidServer
		}
		if id != "" {
			others++
		}
	}
	account, exists := a.byID[server.ID]
	if !exists && others >= MaxEnterpriseServers {
		return nil, ErrTooManyServers
	}
	if !exists || account.Server != server {
		account = a.newAccount(server)
	}
	if err := account.Credential.Set(token); err != nil {
		return nil, err
	}
	a.byID[server.ID] = account
	return account, nil
}

// Clear forgets github.com's token, or an Enterprise server altogether.
func (a *Accounts) Clear(id string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if id == "" {
		a.byID[""].Credential.Clear()
		return
	}
	delete(a.byID, id)
}

// Checker is a client for server with no token of its own, for CheckToken.
func (a *Accounts) Checker(server Server) (*Client, error) {
	if server.ID == "" {
		dotcom, _ := a.Get("")
		server = dotcom.Server
	} else if err := server.Validate(); err != nil {
		return nil, err
	}
	return NewClient(&Credential{}, server.APIURL, a.version), nil
}
