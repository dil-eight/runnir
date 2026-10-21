package github

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestServerValidate(t *testing.T) {
	const id = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
	ok := []Server{
		{ID: id, APIURL: "https://github.company.com/api/v3", WebHost: "github.company.com"},
		{ID: id, APIURL: "https://api.company.ghe.com", WebHost: "company.ghe.com"},
		{ID: id, APIURL: "https://ghe.example:8443/api/v3", WebHost: "ghe.example"},
		{ID: id, APIURL: "http://127.0.0.1:3000", WebHost: "ghe.test"},
	}
	for _, s := range ok {
		if err := s.Validate(); err != nil {
			t.Errorf("%+v: %v", s, err)
		}
	}
	bad := map[string]Server{
		"id not a UUID":   {ID: "x", APIURL: "https://github.company.com/api/v3", WebHost: "github.company.com"},
		"http off a loop": {ID: id, APIURL: "http://github.company.com/api/v3", WebHost: "github.company.com"},
		"user info":       {ID: id, APIURL: "https://user:pw@github.company.com", WebHost: "github.company.com"},
		"query":           {ID: id, APIURL: "https://github.company.com/api/v3?x=1", WebHost: "github.company.com"},
		"fragment":        {ID: id, APIURL: "https://github.company.com/api/v3#x", WebHost: "github.company.com"},
		"no host":         {ID: id, APIURL: "https:///api/v3", WebHost: "github.company.com"},
		"other scheme":    {ID: id, APIURL: "ftp://github.company.com", WebHost: "github.company.com"},
		"web github.com":  {ID: id, APIURL: "https://github.company.com/api/v3", WebHost: "github.com"},
		"web host spaces": {ID: id, APIURL: "https://github.company.com/api/v3", WebHost: "bad host"},
		"web host case":   {ID: id, APIURL: "https://github.company.com/api/v3", WebHost: "GitHub.Company.com"},
	}
	for name, s := range bad {
		if err := s.Validate(); !errors.Is(err, ErrInvalidServer) {
			t.Errorf("%s: want ErrInvalidServer, got %v", name, err)
		}
	}
	if err := DotCom("").Validate(); err != nil {
		t.Errorf("github.com: %v", err)
	}
	if got := DotCom("").APIURL; got != "https://api.github.com" {
		t.Errorf("github.com API = %q", got)
	}
}

func TestNormalizeHost(t *testing.T) {
	for in, want := range map[string]string{"GitHub.Company.com": "github.company.com", "ghe.example:2222": "ghe.example", "[::1]:22": "::1"} {
		if got := NormalizeHost(in); got != want {
			t.Errorf("NormalizeHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestClientRefusesRedirectToAnotherOrigin(t *testing.T) {
	leaked := make(chan string, 1)
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked <- r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer other.Close()
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/user", http.StatusFound)
	}))
	defer api.Close()
	credential := &Credential{}
	if err := credential.Set("ghp_test"); err != nil {
		t.Fatal(err)
	}
	client := NewClient(credential, api.URL, "test")
	var out map[string]any
	if err := client.get(t.Context(), "/user", nil, &out); err == nil {
		t.Fatal("a redirect to another origin was followed")
	}
	select {
	case header := <-leaked:
		t.Fatalf("the other origin was asked (Authorization %q)", header)
	default:
	}
}

func TestClientFollowsRedirectOnItsOrigin(t *testing.T) {
	var api *httptest.Server
	api = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/repos/old/name" {
			http.Redirect(w, r, api.URL+"/repos/new/name", http.StatusMovedPermanently)
			return
		}
		if r.Header.Get("Authorization") != "Bearer ghp_test" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"full_name":"new/name"}`))
	}))
	defer api.Close()
	credential := &Credential{}
	_ = credential.Set("ghp_test")
	client := NewClient(credential, api.URL, "test")
	var out struct {
		FullName string `json:"full_name"`
	}
	if err := client.get(t.Context(), "/repos/old/name", nil, &out); err != nil || out.FullName != "new/name" {
		t.Fatalf("renamed repository = %+v, %v", out, err)
	}
}
