//go:build windows

package localrun

import "os/exec"

func setProcessGroup(*exec.Cmd) {}

// Windows has no process-group interrupt for console programs started this
// way; act is stopped at once and the cleanup removes its containers.
func interruptGroup(cmd *exec.Cmd) error { return cmd.Process.Kill() }

func killGroup(cmd *exec.Cmd) error { return cmd.Process.Kill() }
