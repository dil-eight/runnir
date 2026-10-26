package dispatch

import "testing"

func TestValuesThatAreCredentialsAreRecognised(t *testing.T) {
	for _, value := range []string{
		"ghp_abcdefghijklmnopqrstuvwxyz0123456789",
		"token github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
		"AKIAABCDEFGHIJKLMNOP",
		"use AKIAABCDEFGHIJKLMNOP here",
		"xoxb-123456789012-abcdefghij",
		"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc_DEF-123",
		"-----BEGIN RSA PRIVATE KEY-----",
		"sk-abcdefghijklmnopqrstuvwx",
	} {
		if !LooksSecretValue(value) {
			t.Errorf("%q should look secret", value)
		}
	}
	for _, value := range []string{
		"", "staging", "true", "release/1.4", "v1.2.0", "deploy the fix for #12",
		"ghp_short", "task-list-item-with-a-long-name", "AKIA", "backup-2026-10-22",
	} {
		if LooksSecretValue(value) {
			t.Errorf("%q should not look secret", value)
		}
	}
}
