// runtime_launcher executes an SDK consumer through the SDK-owned dynamic
// loader. It is a static executable, so it does not borrow a host loader or
// shell before establishing the declared runtime boundary.
package main

import (
	"debug/elf"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const (
	loaderVariable  = "RULES_FIPS_RUNTIME_LOADER"
	libraryVariable = "RULES_FIPS_RUNTIME_LIBRARY_PATH"
	programVariable = "RULES_FIPS_RUNTIME_PROGRAM"
	qemuVariable    = "RULES_FIPS_QEMU_AARCH64"
)

// Set by the shared static Go rule. Target launchers execute their loader
// directly; execution-configured launchers use this declared emulator only
// when the loader architecture differs from the execution host.
var qemuAarch64 string

type command struct {
	executable  string
	arguments   []string
	environment []string
}

func main() {
	prepared, err := prepare(os.Args[1:], os.Environ())
	if err != nil {
		fmt.Fprintf(os.Stderr, "runtime launcher: %v\n", err)
		os.Exit(78)
	}
	if err := syscall.Exec(prepared.executable, prepared.arguments, prepared.environment); err != nil {
		fmt.Fprintf(os.Stderr, "runtime launcher: %v\n", err)
		os.Exit(78)
	}
}

func prepare(arguments, environment []string) (command, error) {
	originalWorkingDirectory, err := os.Getwd()
	if err != nil {
		return command{}, fmt.Errorf("read original working directory: %w", err)
	}
	loader, err := executableFromEnvironment(loaderVariable)
	if err != nil {
		return command{}, err
	}
	program, err := executableFromEnvironment(programVariable)
	if err != nil {
		return command{}, err
	}
	executableIdentity, err := os.Executable()
	if err != nil {
		return command{}, fmt.Errorf("identify runtime launcher executable: %w", err)
	}
	program = selectedProgram(program, executableIdentity)
	libraryPath := os.Getenv(libraryVariable)
	if libraryPath == "" {
		return command{}, fmt.Errorf("%s is required", libraryVariable)
	}
	libraries, err := absoluteBeforeChdir(libraryPath)
	if err != nil {
		return command{}, fmt.Errorf("resolve runtime library path: %w", err)
	}
	executable, loaderArguments, err := loaderCommand(loader)
	if err != nil {
		return command{}, err
	}
	if executable != loader {
		environment = withEnvironment(environment, qemuVariable, executable)
	}
	loaderArguments = append(loaderArguments,
		loader,
		"--library-path", libraries,
		"--argv0", os.Args[0],
		program,
	)
	for _, argument := range arguments {
		loaderArguments = append(loaderArguments, resolveArgument(argument, originalWorkingDirectory))
	}
	return command{
		executable:  executable,
		arguments:   loaderArguments,
		environment: resolvedEnvironment(environment),
	}, nil
}

func loaderCommand(loader string) (string, []string, error) {
	if qemuAarch64 == "" {
		return loader, nil, nil
	}
	file, err := elf.Open(loader)
	if err != nil {
		return "", nil, fmt.Errorf("inspect runtime loader %s: %w", loader, err)
	}
	machine := file.Machine
	if err := file.Close(); err != nil {
		return "", nil, fmt.Errorf("close runtime loader %s: %w", loader, err)
	}
	if (runtime.GOARCH == "amd64" && machine == elf.EM_X86_64) ||
		(runtime.GOARCH == "arm64" && machine == elf.EM_AARCH64) {
		return loader, nil, nil
	}
	if runtime.GOARCH != "amd64" || machine != elf.EM_AARCH64 {
		return "", nil, fmt.Errorf("unsupported execution host %s for loader machine %s", runtime.GOARCH, machine)
	}
	declaredQEMU := os.Getenv(qemuVariable)
	if declaredQEMU == "" {
		declaredQEMU = qemuAarch64
	}
	qemu, err := declaredExecutable(declaredQEMU)
	if err != nil {
		return "", nil, fmt.Errorf("resolve declared AArch64 emulator: %w", err)
	}
	return qemu, []string{qemu}, nil
}

func withEnvironment(environment []string, name, value string) []string {
	prefix := name + "="
	result := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
		}
	}
	return append(result, prefix+value)
}

func declaredExecutable(path string) (string, error) {
	candidates := []string{path}
	if !filepath.IsAbs(path) {
		if absolute, err := filepath.Abs(path); err == nil {
			candidates = append(candidates, absolute)
		}
	}
	if relative, found := strings.CutPrefix(path, "external/"); found {
		for _, variable := range []string{"RUNFILES_DIR", "TEST_SRCDIR"} {
			if root := os.Getenv(variable); root != "" {
				candidates = append(candidates, filepath.Join(root, relative))
			}
		}
	}
	for _, candidate := range candidates {
		info, err := os.Stat(candidate)
		if err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return filepath.Abs(candidate)
		}
	}
	return "", fmt.Errorf("declared executable is unavailable: %s", path)
}

func selectedProgram(defaultProgram, invokedAs string) string {
	candidate := filepath.Join(filepath.Dir(defaultProgram), ".real-"+filepath.Base(invokedAs))
	info, err := os.Stat(candidate)
	if err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
		return candidate
	}
	return defaultProgram
}

func executableFromEnvironment(name string) (string, error) {
	value := os.Getenv(name)
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	path, err := absoluteBeforeChdir(value)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", name, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("read %s %s: %w", name, path, err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("%s is not executable: %s", name, path)
	}
	return path, nil
}

func absoluteBeforeChdir(path string) (string, error) {
	const marker = "/proc/self/cwd/"
	if strings.HasPrefix(path, marker) {
		workingDirectory, err := os.Getwd()
		if err != nil {
			return "", err
		}
		path = filepath.Join(workingDirectory, strings.TrimPrefix(path, marker))
	}
	return filepath.Abs(path)
}

func resolvedEnvironment(environment []string) []string {
	removed := map[string]struct{}{
		"LD_LIBRARY_PATH": {},
		"LD_PRELOAD":      {},
	}
	result := make([]string, 0, len(environment))
	workingDirectory, err := os.Getwd()
	if err != nil {
		workingDirectory = "."
	}
	marker := "/proc/self/cwd/"
	opaque := map[string]struct{}{
		"ERL_AFLAGS": {},
		"ERL_FLAGS":  {},
		"ERL_ZFLAGS": {},
	}
	for _, entry := range environment {
		name, _, found := strings.Cut(entry, "=")
		if !found {
			continue
		}
		if _, discard := removed[name]; !discard {
			if _, preserve := opaque[name]; preserve {
				result = append(result, entry)
			} else {
				result = append(result, strings.ReplaceAll(entry, marker, workingDirectory+string(filepath.Separator)))
			}
		}
	}
	return result
}

func resolveArgument(argument, workingDirectory string) string {
	const marker = "/proc/self/cwd/"
	resolved := strings.ReplaceAll(argument, marker, workingDirectory+string(filepath.Separator))
	if strings.HasPrefix(resolved, "bazel-out/") || strings.HasPrefix(resolved, "external/") {
		return filepath.Join(workingDirectory, resolved)
	}
	return resolved
}
