// runtime_launcher executes an SDK consumer through the SDK-owned dynamic
// loader. It is a static executable, so it does not borrow a host loader or
// shell before establishing the declared runtime boundary.
package main

import (
	"debug/elf"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const (
	loaderVariable          = "RULES_FIPS_RUNTIME_LOADER"
	libraryVariable         = "RULES_FIPS_RUNTIME_LIBRARY_PATH"
	programVariable         = "RULES_FIPS_RUNTIME_PROGRAM"
	argv0Variable           = "RULES_FIPS_RUNTIME_ARGV0"
	inhibitCacheVariable    = "RULES_FIPS_RUNTIME_INHIBIT_CACHE"
	pathEnvironmentVariable = "RULES_FIPS_RUNTIME_PATH_ENVIRONMENT"
	qemuVariable            = "RULES_FIPS_QEMU_AARCH64"
	sidecarSuffix           = ".runtime.env"
)

// Set by the shared static Go rule. Target launchers execute their loader
// directly; execution-configured launchers use this declared emulator only
// when the loader architecture differs from the execution host.
var qemuAarch64 string

type command struct {
	executable   string
	arguments    []string
	environment  []string
	libraryPaths []string
	program      string
}

func main() {
	prepared, err := prepare(os.Args[1:], os.Environ())
	if err != nil {
		fmt.Fprintf(os.Stderr, "runtime launcher: %v\n", err)
		os.Exit(78)
	}
	if err := validateDeclaredClosure(prepared.program, prepared.libraryPaths); err != nil {
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
	environment, err = environmentWithSidecar(arguments, environment)
	if err != nil {
		return command{}, err
	}
	loader, err := executableFromEnvironment(loaderVariable)
	if err != nil {
		return command{}, err
	}
	defaultProgram, err := executableFromEnvironment(programVariable)
	if err != nil {
		return command{}, err
	}
	executableIdentity, err := os.Executable()
	if err != nil {
		return command{}, fmt.Errorf("identify runtime launcher executable: %w", err)
	}
	program := selectedProgram(defaultProgram, executableIdentity)
	programArgv0 := selectedArgv0(os.Getenv(argv0Variable), defaultProgram, program, executableIdentity)
	libraryPath := os.Getenv(libraryVariable)
	if libraryPath == "" {
		return command{}, fmt.Errorf("%s is required", libraryVariable)
	}
	libraries, err := absolutePathList(libraryPath)
	if err != nil {
		return command{}, fmt.Errorf("resolve runtime library path: %w", err)
	}
	environment = withEnvironment(environment, loaderVariable, loader)
	environment = withEnvironment(environment, libraryVariable, libraries)
	environment = withEnvironment(environment, programVariable, program)
	environment, err = resolvePathEnvironment(environment)
	if err != nil {
		return command{}, err
	}
	executable, loaderArguments, err := loaderCommand(loader)
	if err != nil {
		return command{}, err
	}
	if executable != loader {
		environment = withEnvironment(environment, qemuVariable, executable)
	}
	loaderArguments = append(loaderArguments, loader)
	inhibitCache, err := booleanEnvironment(inhibitCacheVariable)
	if err != nil {
		return command{}, err
	}
	if inhibitCache {
		loaderArguments = append(loaderArguments, "--inhibit-cache")
	}
	loaderArguments = append(loaderArguments,
		"--library-path", libraries,
		"--argv0", programArgv0,
		program,
	)
	for _, argument := range arguments {
		loaderArguments = append(loaderArguments, resolveArgument(argument, originalWorkingDirectory))
	}
	return command{
		executable:   executable,
		arguments:    loaderArguments,
		environment:  resolvedEnvironment(environment),
		libraryPaths: strings.Split(libraries, string(os.PathListSeparator)),
		program:      program,
	}, nil
}

func booleanEnvironment(name string) (bool, error) {
	switch os.Getenv(name) {
	case "", "false":
		return false, nil
	case "true":
		return true, nil
	default:
		return false, fmt.Errorf("%s must be true, false, or unset", name)
	}
}

func validateDeclaredClosure(program string, libraryPaths []string) error {
	seen := map[string]struct{}{}
	queue := []string{program}
	for len(queue) > 0 {
		path := queue[0]
		queue = queue[1:]
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		binary, err := elf.Open(path)
		if err != nil {
			return fmt.Errorf("inspect declared ELF %s: %w", path, err)
		}
		libraries, err := binary.ImportedLibraries()
		closeErr := binary.Close()
		if err != nil {
			return fmt.Errorf("read declared ELF dependencies for %s: %w", path, err)
		}
		if closeErr != nil {
			return fmt.Errorf("close declared ELF %s: %w", path, closeErr)
		}
		for _, library := range libraries {
			resolved, err := declaredLibrary(library, libraryPaths)
			if err != nil {
				return fmt.Errorf("resolve dependency %s of %s: %w", library, path, err)
			}
			queue = append(queue, resolved)
		}
	}
	return nil
}

func declaredLibrary(name string, libraryPaths []string) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || strings.Contains(name, "/") {
		return "", fmt.Errorf("DT_NEEDED entry must be a basename: %q", name)
	}
	matches := []string{}
	for _, directory := range libraryPaths {
		candidate := filepath.Join(directory, name)
		info, err := os.Stat(candidate)
		if err == nil && info.Mode().IsRegular() {
			matches = append(matches, candidate)
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("inspect declared library %s: %w", candidate, err)
		}
	}
	if len(matches) != 1 {
		return "", fmt.Errorf("expected exactly one declared library, found %d in %v", len(matches), libraryPaths)
	}
	return matches[0], nil
}

func environmentWithSidecar(arguments, environment []string) ([]string, error) {
	owners := []string{os.Args[0]}
	if len(arguments) > 0 {
		owners = append(owners, arguments[0])
	}
	var content []byte
	var sidecar string
	for _, owner := range owners {
		resolved, err := absoluteBeforeChdir(owner)
		if err != nil {
			return nil, fmt.Errorf("resolve runtime sidecar owner: %w", err)
		}
		sidecar = resolved + sidecarSuffix
		content, err = os.ReadFile(sidecar)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("read runtime sidecar %s: %w", sidecar, err)
		}
		content = nil
	}
	if content == nil {
		required := []string{loaderVariable, libraryVariable, programVariable}
		configured := 0
		for _, name := range required {
			if os.Getenv(name) != "" {
				configured++
			}
		}
		if configured == len(required) {
			return environment, nil
		}
		if configured != 0 {
			return nil, fmt.Errorf("runtime environment is incomplete; configure all of %s", strings.Join(required, ", "))
		}
		return environment, nil
	}
	for lineNumber, line := range strings.Split(strings.TrimSuffix(string(content), "\n"), "\n") {
		name, value, found := strings.Cut(line, "=")
		if !found || name == "" || strings.ContainsRune(name, '\x00') || strings.ContainsRune(value, '\x00') {
			return nil, fmt.Errorf("invalid runtime sidecar assignment on line %d", lineNumber+1)
		}
		if err := os.Setenv(name, value); err != nil {
			return nil, fmt.Errorf("apply runtime sidecar assignment %s: %w", name, err)
		}
		environment = withEnvironment(environment, name, value)
	}
	return environment, nil
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
	candidates, err := declaredPathCandidates(path)
	if err != nil {
		return "", err
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
	candidate := filepath.Join(filepath.Dir(invokedAs), ".real-"+filepath.Base(invokedAs))
	info, err := os.Stat(candidate)
	if err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
		return candidate
	}
	return defaultProgram
}

func selectedArgv0(configured, defaultProgram, program, invokedAs string) string {
	if configured != "" {
		return configured
	}
	if program != defaultProgram {
		return invokedAs
	}
	return program
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
	candidates, err := declaredPathCandidates(path)
	if err != nil {
		return "", err
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return filepath.Abs(candidate)
		}
	}
	return filepath.Abs(candidates[0])
}

func absolutePathList(value string) (string, error) {
	paths := strings.Split(value, string(os.PathListSeparator))
	resolved := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" {
			return "", errors.New("runtime library path contains an empty entry")
		}
		absolute, err := absoluteBeforeChdir(path)
		if err != nil {
			return "", err
		}
		resolved = append(resolved, absolute)
	}
	return strings.Join(resolved, string(os.PathListSeparator)), nil
}

func resolvePathEnvironment(environment []string) ([]string, error) {
	names := os.Getenv(pathEnvironmentVariable)
	if names == "" {
		return environment, nil
	}
	for _, name := range strings.Split(names, ",") {
		if !validEnvironmentName(name) {
			return nil, fmt.Errorf("%s contains an invalid variable name: %q", pathEnvironmentVariable, name)
		}
		value := os.Getenv(name)
		if value == "" {
			return nil, fmt.Errorf("declared runtime path environment %s is empty", name)
		}
		resolved, err := absolutePathList(value)
		if err != nil {
			return nil, fmt.Errorf("resolve declared runtime path environment %s: %w", name, err)
		}
		for _, path := range strings.Split(resolved, string(os.PathListSeparator)) {
			if _, err := os.Stat(path); err != nil {
				return nil, fmt.Errorf("inspect declared runtime path %s for %s: %w", path, name, err)
			}
		}
		environment = withEnvironment(environment, name, resolved)
		if err := os.Setenv(name, resolved); err != nil {
			return nil, fmt.Errorf("apply declared runtime path environment %s: %w", name, err)
		}
	}
	return environment, nil
}

func validEnvironmentName(name string) bool {
	if name == "" {
		return false
	}
	for index, character := range name {
		if (character >= 'A' && character <= 'Z') || character == '_' ||
			(index > 0 && character >= '0' && character <= '9') {
			continue
		}
		return false
	}
	return true
}

func declaredPathCandidates(path string) ([]string, error) {
	const marker = "/proc/self/cwd/"
	if path == "" {
		return nil, errors.New("declared path is empty")
	}
	if filepath.IsAbs(path) && !strings.HasPrefix(path, marker) {
		return []string{path}, nil
	}

	workingDirectory, err := os.Getwd()
	if err != nil {
		return nil, fmt.Errorf("read working directory: %w", err)
	}
	relative := strings.TrimPrefix(path, marker)
	candidates := []string{filepath.Join(workingDirectory, relative)}
	for _, executable := range []string{os.Args[0], executablePath()} {
		absolute, err := filepath.Abs(executable)
		if err == nil {
			if root := executionRootFromPath(absolute); root != "" {
				candidates = appendUnique(candidates, filepath.Join(root, relative))
			}
		}
	}
	for _, runfilesRoot := range runfilesRoots() {
		if external, found := strings.CutPrefix(relative, "external/"); found {
			candidates = append(candidates, filepath.Join(runfilesRoot, external))
			continue
		}
		if strings.HasPrefix(relative, "bazel-out/") {
			if _, output, found := strings.Cut(relative, "/bin/"); found {
				candidates = append(candidates, filepath.Join(runfilesRoot, runfilesWorkspace(), output))
			}
			continue
		}
		candidates = append(candidates, filepath.Join(runfilesRoot, runfilesWorkspace(), relative))
	}
	return candidates, nil
}

func executablePath() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	return executable
}

func executionRootFromPath(path string) string {
	for _, directory := range []string{"bazel-out", "external"} {
		marker := string(filepath.Separator) + directory + string(filepath.Separator)
		if index := strings.Index(path, marker); index >= 0 {
			return path[:index]
		}
	}
	return ""
}

func runfilesRoots() []string {
	roots := []string{}
	for _, variable := range []string{"RUNFILES_DIR", "TEST_SRCDIR"} {
		if root := os.Getenv(variable); root != "" {
			roots = appendUnique(roots, root)
		}
	}
	if executable, err := os.Executable(); err == nil {
		if root := runfilesRootFromPath(executable); root != "" {
			roots = appendUnique(roots, root)
		}
	}
	if absolute, err := filepath.Abs(os.Args[0]); err == nil {
		if root := runfilesRootFromPath(absolute); root != "" {
			roots = appendUnique(roots, root)
		}
	}
	if workingDirectory, err := os.Getwd(); err == nil {
		if root := runfilesRootFromPath(workingDirectory); root != "" {
			roots = appendUnique(roots, root)
		}
	}
	return roots
}

func runfilesRootFromPath(path string) string {
	const separator = ".runfiles" + string(filepath.Separator)
	index := strings.Index(path, separator)
	if index < 0 {
		return ""
	}
	return path[:index+len(".runfiles")]
}

func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func runfilesWorkspace() string {
	if workspace := os.Getenv("TEST_WORKSPACE"); workspace != "" {
		return workspace
	}
	return "_main"
}

func resolvedEnvironment(environment []string) []string {
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
		if strings.HasPrefix(name, "LD_") {
			continue
		}
		if _, preserve := opaque[name]; preserve {
			result = append(result, entry)
		} else {
			result = append(result, strings.ReplaceAll(entry, marker, workingDirectory+string(filepath.Separator)))
		}
	}
	return result
}

func resolveArgument(argument, workingDirectory string) string {
	const marker = "/proc/self/cwd/"
	if strings.HasPrefix(argument, marker) || strings.HasPrefix(argument, "bazel-out/") ||
		strings.HasPrefix(argument, "external/") {
		if resolved, err := absoluteBeforeChdir(argument); err == nil {
			if _, err := os.Stat(resolved); err == nil {
				return resolved
			}
		}
	}
	resolved := strings.ReplaceAll(argument, marker, workingDirectory+string(filepath.Separator))
	if strings.HasPrefix(resolved, "bazel-out/") || strings.HasPrefix(resolved, "external/") {
		return filepath.Join(workingDirectory, resolved)
	}
	return resolved
}
