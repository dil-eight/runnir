package github

import (
	"errors"
	"fmt"
	"testing"
)

const enterpriseID = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"

func enterprise(id, host string) Server {
	return Server{ID: id, APIURL: "https://" + host + "/api/v3", WebHost: host}
}

func TestAccountsKeepTokensApart(t *testing.T) {
	accounts := NewAccounts("", "test")
	dotcom, ok := accounts.Get("")
	if !ok || dotcom.Server.WebHost != "github.com" {
		t.Fatalf("github.com = %+v, %v", dotcom, ok)
	}
	if _, has := dotcom.Credential.Token(); has {
		t.Fatal("github.com starts without a token")
	}
	if _, err := accounts.Set(DotCom(""), "ghu_dotcom"); err != nil {
		t.Fatal(err)
	}
	company, err := accounts.Set(enterprise(enterpriseID, "github.company.com"), "ghp_company")
	if err != nil {
		t.Fatal(err)
	}
	if token, _ := company.Credential.Token(); token != "ghp_company" {
		t.Fatalf("company token = %q", token)
	}
	if token, _ := dotcom.Credential.Token(); token != "ghu_dotcom" {
		t.Fatalf("github.com token = %q", token)
	}
	if company.Client == dotcom.Client || company.Client.baseURL != "https://github.company.com/api/v3" {
		t.Fatalf("company client = %+v", company.Client)
	}
	if found, ok := accounts.ForHost("GitHub.Company.com:22"); !ok || found != company {
		t.Fatalf("ForHost = %v, %v", found, ok)
	}
	if found, ok := accounts.ForHost("github.com"); !ok || found != dotcom {
		t.Fatalf("ForHost(github.com) = %v, %v", found, ok)
	}
	if _, ok := accounts.ForHost("gitlab.com"); ok {
		t.Fatal("an unknown host matched")
	}
	if _, ok := accounts.ForHost(""); ok {
		t.Fatal("an empty host matched")
	}
	// A github.com request with other URLs keeps github.com's own.
	if same, err := accounts.Set(Server{APIURL: "https://evil.example", WebHost: "evil.example"}, "ghu_again"); err != nil || same != dotcom || dotcom.Server.WebHost != "github.com" {
		t.Fatalf("github.com URLs changed: %+v, %v", same, err)
	}

	accounts.Clear(enterpriseID)
	if _, ok := accounts.Get(enterpriseID); ok {
		t.Fatal("a cleared Enterprise server stays")
	}
	accounts.Clear("")
	if _, ok := accounts.Get(""); !ok {
		t.Fatal("github.com is always there")
	}
	if _, has := dotcom.Credential.Token(); has {
		t.Fatal("github.com's token stays after Clear")
	}
}

func TestAccountsRefuseBadServers(t *testing.T) {
	accounts := NewAccounts("", "test")
	if _, err := accounts.Set(enterprise(enterpriseID, "github.company.com"), "ghp_a"); err != nil {
		t.Fatal(err)
	}
	other := "2c9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
	if _, err := accounts.Set(enterprise(other, "github.company.com"), "ghp_b"); !errors.Is(err, ErrInvalidServer) {
		t.Fatalf("same web host twice: %v", err)
	}
	if _, err := accounts.Set(Server{ID: other, APIURL: "http://ghe.example/api/v3", WebHost: "ghe.example"}, "ghp_b"); !errors.Is(err, ErrInvalidServer) {
		t.Fatalf("http: %v", err)
	}
	if _, err := accounts.Set(enterprise(other, "ghe.example"), "bad token"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("token: %v", err)
	}
	if _, ok := accounts.Get(other); ok {
		t.Fatal("a server with a refused token was kept")
	}
	// Setting the same id again with new URLs replaces its client.
	moved, err := accounts.Set(Server{ID: enterpriseID, APIURL: "https://api.company.ghe.com", WebHost: "company.ghe.com"}, "ghp_c")
	if err != nil || moved.Server.WebHost != "company.ghe.com" || moved.Client.baseURL != "https://api.company.ghe.com" {
		t.Fatalf("replace = %+v, %v", moved, err)
	}
	if _, ok := accounts.ForHost("github.company.com"); ok {
		t.Fatal("the old host still matches")
	}
}

func TestAccountsLimitEnterpriseServers(t *testing.T) {
	accounts := NewAccounts("", "test")
	for i := 0; i < MaxEnterpriseServers; i++ {
		id := fmt.Sprintf("00000000-0000-4000-8000-%012x", i)
		if _, err := accounts.Set(enterprise(id, fmt.Sprintf("ghe%d.example", i)), "ghp_x"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := accounts.Set(enterprise("ffffffff-0000-4000-8000-000000000000", "one-more.example"), "ghp_x"); !errors.Is(err, ErrTooManyServers) {
		t.Fatalf("eleventh server: %v", err)
	}
	// Replacing the token of one already held is not a new server.
	if _, err := accounts.Set(enterprise(fmt.Sprintf("00000000-0000-4000-8000-%012x", 0), "ghe0.example"), "ghp_y"); err != nil {
		t.Fatalf("new token for a held server: %v", err)
	}
}

func TestCheckerUsesTheServersAPI(t *testing.T) {
	accounts := NewAccounts("", "test")
	checker, err := accounts.Checker(enterprise(enterpriseID, "github.company.com"))
	if err != nil || checker.baseURL != "https://github.company.com/api/v3" {
		t.Fatalf("checker = %+v, %v", checker, err)
	}
	if _, has := checker.credential.Token(); has {
		t.Fatal("a checker holds no token")
	}
	if _, err := accounts.Checker(Server{ID: enterpriseID, APIURL: "http://x.example", WebHost: "x.example"}); !errors.Is(err, ErrInvalidServer) {
		t.Fatalf("bad server: %v", err)
	}
	dotcom, err := accounts.Checker(Server{})
	if err != nil || dotcom.baseURL != "https://api.github.com" {
		t.Fatalf("github.com checker = %+v, %v", dotcom, err)
	}
}
