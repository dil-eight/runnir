package github

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
)

func TestAccountRepositoriesComeFromEveryInstallation(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/user/installations":
			_, _ = w.Write([]byte(`{"total_count":2,"installations":[
				{"id":1,"account":{"login":"octocat","type":"User"},"repository_selection":"all","html_url":"https://github.com/settings/installations/1"},
				{"id":2,"account":{"login":"dil-eight","type":"Organization"},"repository_selection":"selected","html_url":"https://github.com/organizations/dil-eight/settings/installations/2"}]}`))
		case r.URL.Path == "/user/installations/1/repositories" && r.URL.Query().Get("page") == "1":
			_, _ = w.Write([]byte(`{"total_count":2,"repositories":[
				{"full_name":"octocat/old","name":"old","owner":{"login":"octocat"},"description":null,"private":false,"default_branch":"main","html_url":"https://github.com/octocat/old","pushed_at":"2025-01-01T00:00:00Z","archived":true,"fork":false,"permissions":{"push":true}},
				{"full_name":"octocat/../x","name":"..","owner":{"login":"octocat"},"private":false}]}`))
		case r.URL.Path == "/user/installations/2/repositories":
			_, _ = w.Write([]byte(`{"total_count":1,"repositories":[
				{"full_name":"dil-eight/runnir","name":"runnir","owner":{"login":"dil-eight"},"description":"` + strings.Repeat("d", 400) + `","private":true,"visibility":"private","default_branch":"main","html_url":"https://github.com/dil-eight/runnir","pushed_at":"2026-10-20T10:00:00Z","permissions":{"push":false}}]}`))
		default:
			t.Errorf("unexpected %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	account, err := client.AccountRepositories(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(account.Installations) != 2 || account.Installations[1].Account != "dil-eight" || account.Installations[1].RepositorySelection != "selected" {
		t.Fatalf("installations = %+v", account.Installations)
	}
	if len(account.Repositories) != 2 || account.Truncated {
		t.Fatalf("repositories = %+v, truncated %v", account.Repositories, account.Truncated)
	}
	newest, old := account.Repositories[0], account.Repositories[1]
	if newest.FullName != "dil-eight/runnir" || newest.Visibility != "private" || newest.CanPush || newest.InstallationID != 2 ||
		len([]rune(newest.Description)) != maxDescriptionChars {
		t.Fatalf("newest = %+v", newest)
	}
	if old.FullName != "octocat/old" || old.Visibility != "public" || !old.Archived || !old.CanPush || old.Description != "" {
		t.Fatalf("old = %+v", old)
	}
}

func TestAccountRepositoriesStopAtTheLimit(t *testing.T) {
	pages := 0
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/user/installations" {
			_, _ = w.Write([]byte(`{"total_count":1,"installations":[{"id":1,"account":{"login":"o","type":"User"}}]}`))
			return
		}
		pages++
		page := r.URL.Query().Get("page")
		var b strings.Builder
		b.WriteString(`{"total_count":5000,"repositories":[`)
		for i := 0; i < 100; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"full_name":"o/r` + page + `-` + strings.Repeat("x", i%3) + string(rune('a'+i%26)) + string(rune('a'+i/26)) + `","name":"r","owner":{"login":"o"}}`)
		}
		b.WriteString("]}")
		_, _ = w.Write([]byte(b.String()))
	})
	account, err := client.AccountRepositories(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(account.Repositories) != maxAccountRepositories || !account.Truncated || pages != 10 {
		t.Fatalf("read %d in %d pages, truncated %v", len(account.Repositories), pages, account.Truncated)
	}
}

func TestValidRepositoryNamesOnlyGitHubRepositories(t *testing.T) {
	for _, good := range []string{"o/r", "dil-eight/runnir", "a1/.github", "o/r.js", "o/r_x-y"} {
		if !ValidRepository(good) {
			t.Errorf("%q refused", good)
		}
	}
	for _, bad := range []string{"", "o", "/r", "o/", "o/r/x", "o/..", "o/.", "-o/r", "o o/r", "o/r?x", "o/r#x", "../r", strings.Repeat("o", 40) + "/r"} {
		if ValidRepository(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestAnInstallationGitHubRefusesDoesNotHideTheOthers(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/user/installations":
			_, _ = w.Write([]byte(`{"total_count":2,"installations":[{"id":1,"account":{"login":"suspended","type":"Organization"}},{"id":2,"account":{"login":"o","type":"User"}}]}`))
		case "/user/installations/1/repositories":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"This installation has been suspended"}`))
		case "/user/installations/2/repositories":
			_, _ = w.Write([]byte(`{"total_count":1,"repositories":[{"full_name":"o/r","name":"r","owner":{"login":"o"}}]}`))
		}
	})
	account, err := client.AccountRepositories(context.Background())
	if err != nil || len(account.Installations) != 2 || len(account.Repositories) != 1 || account.Repositories[0].FullName != "o/r" {
		t.Fatalf("account = %+v, %v", account, err)
	}
}

func TestAnUnauthorizedTokenFailsTheList(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/user/installations" {
			_, _ = w.Write([]byte(`{"total_count":1,"installations":[{"id":1,"account":{"login":"o","type":"User"}}]}`))
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	})
	if _, err := client.AccountRepositories(context.Background()); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v", err)
	}
}

func TestInstallationsSayWhichPermissionsWaitForAnOwner(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/user/installations":
			_, _ = w.Write([]byte(`{"total_count":3,"installations":[
				{"id":1,"account":{"login":"Current","type":"Organization"},"permissions":{"actions":"write","contents":"write","metadata":"read","pull_requests":"read"}},
				{"id":2,"account":{"login":"behind","type":"User"},"permissions":{"actions":"read","metadata":"read"}},
				{"id":3,"account":{"login":"paused","type":"Organization"},"permissions":{"actions":"write","contents":"read","metadata":"read","pull_requests":"read"},"suspended_at":"2026-10-01T00:00:00Z"}]}`))
		case "/user/installations/1/repositories":
			_, _ = w.Write([]byte(`{"total_count":1,"repositories":[{"full_name":"Current/r","name":"r","owner":{"login":"Current"}}]}`))
		case "/user/installations/2/repositories":
			_, _ = w.Write([]byte(`{"total_count":0,"repositories":[]}`))
		default:
			t.Errorf("unexpected %s", r.URL)
		}
	})
	installations, total, err := client.Installations(context.Background())
	if err != nil || total != 3 || len(installations) != 3 {
		t.Fatalf("installations = %+v, %d, %v", installations, total, err)
	}
	if len(installations[0].MissingPermissions) != 0 || installations[0].Suspended {
		t.Fatalf("current = %+v", installations[0])
	}
	if strings.Join(installations[1].MissingPermissions, ",") != "actions: write,contents: read,pull_requests: read" {
		t.Fatalf("behind = %+v", installations[1])
	}
	if !installations[2].Suspended {
		t.Fatalf("paused = %+v", installations[2])
	}
	found, ok, err := client.InstallationFor(context.Background(), "current")
	if err != nil || !ok || found.ID != 1 {
		t.Fatalf("for current = %+v, %v, %v", found, ok, err)
	}
	if _, ok, _ := client.InstallationFor(context.Background(), "nobody"); ok {
		t.Fatal("found an installation for nobody")
	}
	// A suspended installation's repositories are not read.
	account, err := client.AccountRepositories(context.Background())
	if err != nil || len(account.Installations) != 3 || len(account.Repositories) != 1 {
		t.Fatalf("account = %+v, %v", account, err)
	}
}
