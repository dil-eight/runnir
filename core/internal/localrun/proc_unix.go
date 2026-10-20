//go:build !windows

package localrun

import (
	"os/exec"
	"syscall"
)

// act runs in its own process group so an interrupt reaches the programs it
// started too.
func setProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// interruptGroup asks act to stop the way Ctrl-C would: it cancels the jobs
// and removes their containers.
func interruptGroup(cmd *exec.Cmd) error {
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
}

func killGroup(cmd *exec.Cmd) error {
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
