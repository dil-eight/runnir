//go:build !windows

package localrun

import (
	"os/exec"
	"syscall"
)

// PassesValues: secrets and variables reach act through pipes it inherits.
const PassesValues = true

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
