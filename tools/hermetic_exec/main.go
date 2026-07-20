// hermetic_exec reasserts declared environment assignments before replacing
// itself with another executable. It is a generic foreign-build primitive;
// consumers provide both the executable and assignments through the action
// environment.
package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
)

const (
	executableEnvironment  = "RULES_HERMETIC_EXECUTABLE"
	assignmentsEnvironment = "RULES_HERMETIC_EXEC_ENV"
)

func assignments(value string) ([][2]string, error) {
	if value == "" {
		return nil, nil
	}
	lines := strings.Split(value, "\n")
	result := make([][2]string, 0, len(lines))
	for _, line := range lines {
		key, item, ok := strings.Cut(line, "=")
		if !ok || key == "" || strings.ContainsRune(key, '\x00') || strings.ContainsRune(item, '\x00') {
			return nil, fmt.Errorf("invalid environment assignment %q", line)
		}
		result = append(result, [2]string{key, item})
	}
	return result, nil
}

func run() error {
	executable := os.Getenv(executableEnvironment)
	if executable == "" {
		return errors.New(executableEnvironment + " is not set")
	}
	values, err := assignments(os.Getenv(assignmentsEnvironment))
	if err != nil {
		return err
	}
	for _, value := range values {
		if err := os.Setenv(value[0], value[1]); err != nil {
			return fmt.Errorf("set %s: %w", value[0], err)
		}
	}
	arguments := append([]string{executable}, os.Args[1:]...)
	return syscall.Exec(executable, arguments, os.Environ())
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "hermetic_exec:", err)
		os.Exit(72)
	}
}
