// hermetic_busybox dispatches a pinned BusyBox binary without relying on
// BusyBox's argv[0]-through-symlink applet detection.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var busyboxPath string

func executionRoot() (string, error) {
	if root := os.Getenv("RULES_FIPS_EXEC_ROOT"); root != "" {
		return root, nil
	}
	invoked, err := filepath.Abs(os.Args[0])
	if err != nil {
		return "", fmt.Errorf("resolve launcher path: %w", err)
	}
	marker := string(filepath.Separator) + "bazel-out" + string(filepath.Separator)
	if index := strings.Index(invoked, marker); index > 0 {
		return invoked[:index], nil
	}
	root, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("get working directory: %w", err)
	}
	return root, nil
}

func run() error {
	if busyboxPath == "" {
		return fmt.Errorf("empty embedded BusyBox path")
	}
	root, err := executionRoot()
	if err != nil {
		return err
	}
	busybox := busyboxPath
	if !filepath.IsAbs(busybox) {
		busybox = filepath.Join(root, busybox)
	}
	if _, err := os.Stat(busybox); err != nil {
		return fmt.Errorf("access BusyBox %q: %w", busybox, err)
	}
	applet := filepath.Base(os.Args[0])
	arguments := []string{busybox, applet}
	arguments = append(arguments, os.Args[1:]...)
	if err := syscall.Exec(busybox, arguments, os.Environ()); err != nil {
		return fmt.Errorf("execute BusyBox applet %q: %w", applet, err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "hermetic BusyBox: %v\n", err)
		os.Exit(127)
	}
}
