package github

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Installation is an account where the Runnir Desktop app is installed and
// the user can see the installation.
type Installation struct {
	ID                  int64
	Account             string
	AccountType         string
	RepositorySelection string
	HTMLURL             string
	// Permissions Runnir needs that the installation has not granted, as
	// "name: level", sorted.
	MissingPermissions []string
	Suspended          bool
}

// RequiredPermissions are the repository permissions Runnir Desktop asks
// for (docs/security/github-authentication.md). An installation granted less
// has not accepted an update of the app's permissions.
var RequiredPermissions = map[string]string{"actions": "write", "contents": "read", "metadata": "read", "pull_requests": "read"}

// missingPermissions lists what granted lacks of RequiredPermissions; write
// covers read, and admin covers both.
func missingPermissions(granted map[string]string) []string {
	rank := map[string]int{"read": 1, "write": 2, "admin": 3}
	var missing []string
	for name, level := range RequiredPermissions {
		if rank[granted[name]] < rank[level] {
			missing = append(missing, name+": "+level)
		}
	}
	sort.Strings(missing)
	return missing
}

type installationJSON struct {
	ID      int64 `json:"id"`
	Account struct {
		Login string `json:"login"`
		Type  string `json:"type"`
	} `json:"account"`
	RepositorySelection string            `json:"repository_selection"`
	HTMLURL             string            `json:"html_url"`
	Permissions         map[string]string `json:"permissions"`
	SuspendedAt         *time.Time        `json:"suspended_at"`
}

// Installations lists the installations of the app the user can see, up to
// 100, and how many there are.
func (c *Client) Installations(ctx context.Context) ([]Installation, int, error) {
	var body struct {
		TotalCount    int                `json:"total_count"`
		Installations []installationJSON `json:"installations"`
	}
	if err := c.get(ctx, "/user/installations", url.Values{"per_page": {strconv.Itoa(maxInstallations)}}, &body); err != nil {
		return nil, 0, err
	}
	installations := make([]Installation, 0, len(body.Installations))
	for _, i := range body.Installations {
		installations = append(installations, Installation{
			ID: i.ID, Account: i.Account.Login, AccountType: i.Account.Type, RepositorySelection: i.RepositorySelection,
			HTMLURL: i.HTMLURL, MissingPermissions: missingPermissions(i.Permissions), Suspended: i.SuspendedAt != nil,
		})
	}
	return installations, body.TotalCount, nil
}

// InstallationFor finds the installation of an account (an owner of
// repositories), ignoring case; false when the user cannot see one.
func (c *Client) InstallationFor(ctx context.Context, account string) (Installation, bool, error) {
	installations, _, err := c.Installations(ctx)
	if err != nil {
		return Installation{}, false, err
	}
	for _, installation := range installations {
		if strings.EqualFold(installation.Account, account) {
			return installation, true, nil
		}
	}
	return Installation{}, false, nil
}

// AccountRepository is a repository the user's token reaches.
type AccountRepository struct {
	FullName       string
	Owner          string
	Name           string
	Description    string
	Visibility     string
	DefaultBranch  string
	HTMLURL        string
	PushedAt       time.Time
	Archived       bool
	Fork           bool
	CanPush        bool
	InstallationID int64
}

// AccountRepositories is what ListAccountRepositories read.
type AccountRepositories struct {
	Installations []Installation
	// Newest push first.
	Repositories []AccountRepository
	// More repositories exist than were read.
	Truncated bool
}

const (
	maxInstallations       = 100
	maxAccountRepositories = 1000
	maxDescriptionChars    = 300
)

// AccountRepositories lists the repositories a GitHub App user token
// reaches: those of every installation the user can see, up to 1,000. An
// installation whose repositories GitHub refuses (suspended, say) is listed
// without them instead of failing the rest.
func (c *Client) AccountRepositories(ctx context.Context) (AccountRepositories, error) {
	if c.credential.Kind() != TokenAppUser {
		return c.userRepositories(ctx)
	}
	installations, total, err := c.Installations(ctx)
	if err != nil {
		return AccountRepositories{}, err
	}
	out := AccountRepositories{Installations: installations, Truncated: total > len(installations)}
	seen := map[string]bool{}
	for _, installation := range installations {
		if installation.Suspended {
			continue
		}
	installationRepositories:
		for page := 1; ; page++ {
			if len(out.Repositories) >= maxAccountRepositories {
				out.Truncated = true
				break
			}
			var body struct {
				TotalCount   int `json:"total_count"`
				Repositories []struct {
					FullName string `json:"full_name"`
					Name     string `json:"name"`
					Owner    struct {
						Login string `json:"login"`
					} `json:"owner"`
					Description   *string    `json:"description"`
					Private       bool       `json:"private"`
					Visibility    string     `json:"visibility"`
					DefaultBranch string     `json:"default_branch"`
					HTMLURL       string     `json:"html_url"`
					PushedAt      *time.Time `json:"pushed_at"`
					Archived      bool       `json:"archived"`
					Fork          bool       `json:"fork"`
					Permissions   struct {
						Push bool `json:"push"`
					} `json:"permissions"`
				} `json:"repositories"`
			}
			query := url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}
			path := fmt.Sprintf("/user/installations/%d/repositories", installation.ID)
			if err := c.get(ctx, path, query, &body); errors.Is(err, ErrNotVisible) {
				break installationRepositories
			} else if err != nil {
				return AccountRepositories{}, err
			}
			for _, r := range body.Repositories {
				if seen[r.FullName] || !ValidRepository(r.FullName) {
					continue
				}
				seen[r.FullName] = true
				visibility := r.Visibility
				if visibility == "" {
					visibility = "public"
					if r.Private {
						visibility = "private"
					}
				}
				description := ""
				if r.Description != nil {
					description = truncate(*r.Description, maxDescriptionChars)
				}
				out.Repositories = append(out.Repositories, AccountRepository{
					FullName: r.FullName, Owner: r.Owner.Login, Name: r.Name, Description: description,
					Visibility: visibility, DefaultBranch: r.DefaultBranch, HTMLURL: r.HTMLURL, PushedAt: deref(r.PushedAt),
					Archived: r.Archived, Fork: r.Fork, CanPush: r.Permissions.Push, InstallationID: installation.ID,
				})
			}
			if len(body.Repositories) < 100 || page*100 >= body.TotalCount {
				break
			}
		}
	}
	if len(out.Repositories) > maxAccountRepositories {
		out.Repositories = out.Repositories[:maxAccountRepositories]
		out.Truncated = true
	}
	sort.SliceStable(out.Repositories, func(i, j int) bool {
		return out.Repositories[i].PushedAt.After(out.Repositories[j].PushedAt)
	})
	return out, nil
}

// repositoryJSON is a repository as GitHub lists it.
type repositoryJSON struct {
	FullName string `json:"full_name"`
	Name     string `json:"name"`
	Owner    struct {
		Login string `json:"login"`
	} `json:"owner"`
	Description   *string    `json:"description"`
	Private       bool       `json:"private"`
	Visibility    string     `json:"visibility"`
	DefaultBranch string     `json:"default_branch"`
	HTMLURL       string     `json:"html_url"`
	PushedAt      *time.Time `json:"pushed_at"`
	Archived      bool       `json:"archived"`
	Fork          bool       `json:"fork"`
	Permissions   struct {
		Push bool `json:"push"`
	} `json:"permissions"`
}

func (r repositoryJSON) accountRepository(installationID int64) AccountRepository {
	visibility := r.Visibility
	if visibility == "" {
		visibility = "public"
		if r.Private {
			visibility = "private"
		}
	}
	description := ""
	if r.Description != nil {
		description = truncate(*r.Description, maxDescriptionChars)
	}
	return AccountRepository{
		FullName: r.FullName, Owner: r.Owner.Login, Name: r.Name, Description: description,
		Visibility: visibility, DefaultBranch: r.DefaultBranch, HTMLURL: r.HTMLURL, PushedAt: deref(r.PushedAt),
		Archived: r.Archived, Fork: r.Fork, CanPush: r.Permissions.Push, InstallationID: installationID,
	}
}

// userRepositories lists what a personal token reaches (GET /user/repos):
// installations of the Runnir Desktop app do not apply to it.
func (c *Client) userRepositories(ctx context.Context) (AccountRepositories, error) {
	var out AccountRepositories
	seen := map[string]bool{}
	for page := 1; page <= maxAccountRepositories/100; page++ {
		var repositories []repositoryJSON
		query := url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}, "sort": {"pushed"},
			"affiliation": {"owner,collaborator,organization_member"}}
		if err := c.get(ctx, "/user/repos", query, &repositories); err != nil {
			return AccountRepositories{}, err
		}
		for _, r := range repositories {
			if seen[r.FullName] || !ValidRepository(r.FullName) {
				continue
			}
			seen[r.FullName] = true
			out.Repositories = append(out.Repositories, r.accountRepository(0))
		}
		if len(repositories) < 100 {
			return out, nil
		}
	}
	out.Truncated = true
	return out, nil
}

var (
	ownerPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`)
	namePattern  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)
)

// ValidRepository reports whether fullName is "owner/name" with the
// characters GitHub allows, so it can only name a repository on github.com.
func ValidRepository(fullName string) bool {
	owner, name, ok := strings.Cut(fullName, "/")
	return ok && ownerPattern.MatchString(owner) && namePattern.MatchString(name) && name != "." && name != ".."
}

func truncate(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return string(runes[:limit-1]) + "…"
}
