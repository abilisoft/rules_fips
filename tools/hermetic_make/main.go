// hermetic_make launches a pinned dynamically linked GNU make through a
// pinned musl loader. It also points recursive make invocations back at this
// statically linked launcher.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	loaderPath  string
	libraryPath string
	makePath    string
)

func absoluteFromWorkingDirectory(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("empty embedded tool path")
	}
	if filepath.IsAbs(path) {
		return path, nil
	}
	executionRoot := os.Getenv("RULES_FIPS_EXEC_ROOT")
	if executionRoot == "" {
		var err error
		executionRoot, err = os.Getwd()
		if err != nil {
			return "", fmt.Errorf("get working directory: %w", err)
		}
	}
	return filepath.Join(executionRoot, path), nil
}

func environmentWithMake(path string) []string {
	environment := make([]string, 0, len(os.Environ())+1)
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "MAKE=") {
			continue
		}
		environment = append(environment, entry)
	}
	return append(environment, "MAKE="+path)
}

func run() error {
	loader, err := absoluteFromWorkingDirectory(loaderPath)
	if err != nil {
		return fmt.Errorf("resolve musl loader: %w", err)
	}
	libraries, err := absoluteFromWorkingDirectory(libraryPath)
	if err != nil {
		return fmt.Errorf("resolve musl libraries: %w", err)
	}
	makeBinary, err := absoluteFromWorkingDirectory(makePath)
	if err != nil {
		return fmt.Errorf("resolve GNU make: %w", err)
	}
	launcher, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve launcher: %w", err)
	}
	launcher, err = filepath.Abs(launcher)
	if err != nil {
		return fmt.Errorf("make launcher absolute: %w", err)
	}

	arguments := []string{
		loader,
		"--library-path",
		libraries,
		"--argv0",
		launcher,
		makeBinary,
	}
	arguments = append(arguments, os.Args[1:]...)
	if err := syscall.Exec(loader, arguments, environmentWithMake(launcher)); err != nil {
		return fmt.Errorf("execute GNU make: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "hermetic make: %v\n", err)
		os.Exit(127)
	}
}
