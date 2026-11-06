// Package licenses holds Runnir's license and the notices of the third-party
// code linked into the Core (B49), for `runnir licenses`. Both files are
// written by scripts/update-notices.sh; CI fails when they are out of date.
package licenses

import _ "embed"

//go:embed LICENSE
var license string

//go:embed NOTICES.txt
var notices string

// Text is Runnir's license, then the third-party notices.
func Text() string { return license + "\n\n" + notices }
