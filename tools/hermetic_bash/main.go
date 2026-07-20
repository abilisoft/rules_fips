// hermetic_bash launches a pinned GNU Bash through its pinned musl runtime.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	bashPath    string
	libraryPath string
	loaderPath  string
)

func absolute(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("empty embedded tool path")
	}
	if filepath.IsAbs(path) {
		return path, nil
	}
	root, err := executionRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, path), nil
}

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
	loader, err := absolute(loaderPath)
	if err != nil {
		return fmt.Errorf("resolve musl loader: %w", err)
	}
	if _, err := os.Stat(loader); err != nil {
		return fmt.Errorf("access musl loader %q: %w", loader, err)
	}
	bash, err := absolute(bashPath)
	if err != nil {
		return fmt.Errorf("resolve Bash: %w", err)
	}
	if _, err := os.Stat(bash); err != nil {
		return fmt.Errorf("access Bash %q: %w", bash, err)
	}
	libraries, err := absoluteLibraryPath(libraryPath)
	if err != nil {
		return err
	}
	arguments := []string{loader, "--library-path", libraries, bash}
	arguments = append(arguments, os.Args[1:]...)
	if err := syscall.Exec(loader, arguments, os.Environ()); err != nil {
		return fmt.Errorf("execute Bash: %w", err)
	}
	return nil
}

func absoluteLibraryPath(value string) (string, error) {
	paths := filepath.SplitList(value)
	resolved := make([]string, 0, len(paths))
	for _, path := range paths {
		absolutePath, err := absolute(path)
		if err != nil {
			return "", fmt.Errorf("resolve Bash library path: %w", err)
		}
		resolved = append(resolved, absolutePath)
	}
	return strings.Join(resolved, ":"), nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "hermetic Bash: %v\n", err)
		os.Exit(127)
	}
}
