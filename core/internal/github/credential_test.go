package github

import (
	"fmt"
	"strings"
	"sync"
	"testing"
)

func TestCredentialSetClearAndValidation(t *testing.T) {
	var c Credential
	if _, ok := c.Token(); ok {
		t.Fatal("new credential must be empty")
	}
	for _, bad := range []string{"", "has space", "line\nbreak", strings.Repeat("x", 256), "naïve"} {
		if err := c.Set(bad); err != ErrInvalidToken {
			t.Errorf("Set(%q) = %v, want ErrInvalidToken", bad, err)
		}
	}
	if err := c.Set("ghu_example123"); err != nil {
		t.Fatal(err)
	}
	if token, ok := c.Token(); !ok || token != "ghu_example123" {
		t.Fatalf("token = %q, %v", token, ok)
	}
	c.Clear()
	if _, ok := c.Token(); ok {
		t.Fatal("clear did not forget the token")
	}
}

func TestASignInChangesOnlyWhenATokenComesAfterNone(t *testing.T) {
	var a, b Credential
	_ = a.Set("ghu_one")
	first, signIn := a.Generation(), a.SignIn()
	_ = a.Set("ghu_two") // a refreshed token
	if a.Generation() <= first || a.SignIn() != signIn {
		t.Fatalf("refresh: generation %d after %d, sign-in %d after %d", a.Generation(), first, a.SignIn(), signIn)
	}
	same := a.Generation()
	_ = a.Set("ghu_two")
	if a.Generation() != same {
		t.Fatal("the same token again is no change")
	}
	a.Clear()
	if a.Generation() == same || a.SignIn() != signIn {
		t.Fatal("a sign-out changes the generation only")
	}
	_ = a.Set("ghu_three")
	if a.SignIn() == signIn || a.SignIn() != a.Generation() {
		t.Fatal("a token after none is another sign-in")
	}
	_ = b.Set("ghu_one")
	if b.Generation() == a.Generation() || b.SignIn() == a.SignIn() {
		t.Fatal("two credentials share a number")
	}
}

func TestCredentialNeverPrintsTheToken(t *testing.T) {
	var c Credential
	_ = c.Set("ghu_secret")
	for _, text := range []string{fmt.Sprint(&c), fmt.Sprintf("%v", &c), fmt.Sprintf("%s", &c)} {
		if strings.Contains(text, "ghu_secret") {
			t.Fatalf("token leaked in %q", text)
		}
	}
}

func TestCredentialIsSafeForConcurrentUse(t *testing.T) {
	var c Credential
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _ = c.Set("ghu_a") }()
		go func() { defer wg.Done(); _, _ = c.Token(); c.Clear() }()
	}
	wg.Wait()
}
