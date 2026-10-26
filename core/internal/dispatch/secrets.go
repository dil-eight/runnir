package dispatch

import (
	"strings"
	"unicode"
)

// LooksSecret says whether an input's name or description suggests that its
// value is a secret. It is a heuristic: nothing can know what an input
// carries, so callers say which inputs they left out instead of promising
// that no secret is kept. The app's presets use the same rule.
func LooksSecret(name, description string) bool {
	text := strings.ToLower(name + " " + description)
	for _, part := range []string{"secret", "token", "passw", "passphrase", "credential", "apikey", "privatekey"} {
		if strings.Contains(text, part) {
			return true
		}
	}
	nameWords, descriptionWords := words(name), words(description)
	for _, word := range []string{"key", "pat", "pwd", "pass", "otp", "pin", "auth", "cert", "cookie", "session"} {
		if nameWords[word] || descriptionWords[word] {
			return true
		}
	}
	return false
}

// words splits an identifier or a sentence into lowercase words:
// "deployKey" and "deploy_key" both give "deploy" and "key".
func words(text string) map[string]bool {
	out := map[string]bool{}
	var current []rune
	previousWasLower := false
	flush := func() {
		if len(current) > 0 {
			out[string(current)] = true
			current = current[:0]
		}
	}
	for _, r := range text {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if unicode.IsUpper(r) && previousWasLower {
				flush()
			}
			current = append(current, unicode.ToLower(r))
			previousWasLower = unicode.IsLower(r) || unicode.IsDigit(r)
		} else {
			flush()
			previousWasLower = false
		}
	}
	flush()
	return out
}
