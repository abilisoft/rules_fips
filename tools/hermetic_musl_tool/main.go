// hermetic_musl_tool launches a pinned musl-linked build tool through the
// loader and shared libraries bundled with that tool.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var toolchainRoot string
var loaderRelativePath string

const executionRootMarker = "/proc/self/cwd/"

var allowedTools = map[string]struct{}{
	"ar":      {},
	"clang":   {},
	"clang++": {},
	"ld.lld":  {},
	"nm":      {},
	"objcopy": {},
	"objdump": {},
	"ranlib":  {},
	"readelf": {},
	"strip":   {},
}

func absoluteFromExecutionRoot(path, root string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("empty embedded toolchain root")
	}
	if filepath.IsAbs(path) {
		return path, nil
	}
	if root == "" {
		return "", fmt.Errorf("empty execution root")
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

func resolveExecutionRootMarkers(arguments []string, root string) []string {
	resolved := make([]string, 0, len(arguments))
	prefix := filepath.Clean(root) + string(filepath.Separator)
	for _, argument := range arguments {
		resolved = append(resolved, strings.ReplaceAll(argument, executionRootMarker, prefix))
	}
	return resolved
}

func run() error {
	name := filepath.Base(os.Args[0])
	if _, allowed := allowedTools[name]; !allowed {
		return fmt.Errorf("unsupported tool name %q", name)
	}
	execRoot, err := executionRoot()
	if err != nil {
		return err
	}
	toolchain, err := absoluteFromExecutionRoot(toolchainRoot, execRoot)
	if err != nil {
		return err
	}
	wrapper, err := absoluteFromExecutionRoot(os.Args[0], execRoot)
	if err != nil {
		return err
	}
	if loaderRelativePath == "" {
		return fmt.Errorf("empty embedded loader path")
	}
	loader := filepath.Join(toolchain, filepath.FromSlash(loaderRelativePath))
	libraries := filepath.Join(toolchain, "lib") + ":" + filepath.Join(toolchain, "usr", "lib")
	tool := filepath.Join(toolchain, "usr", "bin", name)
	arguments := []string{
		loader,
		"--library-path",
		libraries,
		"--argv0",
		wrapper,
		tool,
	}
	clang := name == "clang" || name == "clang++"
	cc1 := len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "-cc1")
	if clang && !cc1 {
		arguments = append(
			arguments,
			"-fintegrated-cc1",
			"-no-canonical-prefixes",
			"-ccc-install-dir",
			filepath.Dir(wrapper),
		)
	}
	arguments = append(arguments, resolveExecutionRootMarkers(os.Args[1:], execRoot)...)
	if err := os.Setenv("RULES_FIPS_EXEC_ROOT", execRoot); err != nil {
		return fmt.Errorf("publish execution root: %w", err)
	}
	if err := syscall.Exec(loader, arguments, os.Environ()); err != nil {
		return fmt.Errorf("execute %s: %w", tool, err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "hermetic musl tool: %v\n", err)
		os.Exit(127)
	}
}
