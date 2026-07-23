// crypto_activation runs a packaged OpenSSL command through the SDK-owned
// runtime loader. It is compiled as a static executable for both the Bazel
// execution platform and the deployment target.
package main

import (
	"debug/elf"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const (
	launchConfigSuffix = ".rules_elixir_mix.crypto.json"
	libraryVariable    = "RULES_FIPS_RUNTIME_LIBRARY_PATH"
	loaderVariable     = "RULES_FIPS_RUNTIME_LOADER"
	programVariable    = "RULES_FIPS_RUNTIME_PROGRAM"
)

var qemuAarch64 string

type command struct {
	executable     string
	arguments      []string
	environment    []string
	writableCopies []writableCopy
}

type writableCopy struct {
	source      string
	destination string
}

type writableCopyConfiguration struct {
	Source      string `json:"source"`
	Destination string `json:"destination"`
}

type launchConfiguration struct {
	Schema                    int                         `json:"schema"`
	Command                   string                      `json:"command"`
	SDKRoot                   string                      `json:"sdk_root"`
	ActivationRootEnvironment string                      `json:"activation_root_environment"`
	ActivationArgs            []string                    `json:"activation_args"`
	RuntimeEnvironment        map[string]string           `json:"runtime_environment"`
	RuntimeWrapper            string                      `json:"runtime_wrapper"`
	Program                   string                      `json:"program"`
	Arguments                 []string                    `json:"arguments"`
	Environment               map[string]string           `json:"environment"`
	UnsetEnvironment          []string                    `json:"unset_environment"`
	WritableCopies            []writableCopyConfiguration `json:"writable_copies"`
}

func main() {
	if launchConfig, found := packagedLaunchConfig(os.Args[0]); found {
		activation, runtime, err := preparePackagedLaunch(launchConfig, os.Args[1:], os.Environ())
		if err != nil {
			fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
			os.Exit(78)
		}
		if activation.executable != "" {
			if err := ensureOutputParent(activation.arguments[1:]); err != nil {
				fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
				os.Exit(78)
			}
			process := &exec.Cmd{
				Path:   activation.executable,
				Args:   activation.arguments,
				Env:    activation.environment,
				Stdin:  os.Stdin,
				Stdout: os.Stdout,
				Stderr: os.Stderr,
			}
			if err := process.Run(); err != nil {
				fmt.Fprintf(os.Stderr, "crypto activation: packaged activation failed: %v\n", err)
				os.Exit(78)
			}
		}
		if err := materializeWritableCopies(runtime.writableCopies); err != nil {
			fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
			os.Exit(78)
		}
		if err := syscall.Exec(runtime.executable, runtime.arguments, runtime.environment); err != nil {
			fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
			os.Exit(78)
		}
	}

	prepared, err := prepare(os.Args[1:], os.Environ())
	if err != nil {
		fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
		os.Exit(78)
	}
	if err := ensureOutputParent(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
		os.Exit(78)
	}
	if err := syscall.Exec(prepared.executable, prepared.arguments, prepared.environment); err != nil {
		fmt.Fprintf(os.Stderr, "crypto activation: %v\n", err)
		os.Exit(78)
	}
}

func packagedLaunchConfig(invokedAs string) (string, bool) {
	path, err := filepath.Abs(invokedAs + launchConfigSuffix)
	if err != nil {
		return "", false
	}
	info, err := os.Stat(path)
	return path, err == nil && info.Mode().IsRegular()
}

func preparePackagedLaunch(configPath string, arguments, environment []string) (command, command, error) {
	contents, err := os.ReadFile(configPath)
	if err != nil {
		return command{}, command{}, fmt.Errorf("read packaged launch config: %w", err)
	}
	var config launchConfiguration
	if err := json.Unmarshal(contents, &config); err != nil {
		return command{}, command{}, fmt.Errorf("decode packaged launch config: %w", err)
	}
	if config.Schema != 1 {
		return command{}, command{}, fmt.Errorf("unsupported packaged launch schema %d", config.Schema)
	}
	wantedCommand := config.Command
	if wantedCommand == "" {
		wantedCommand = "start"
	}
	if len(arguments) > 1 || len(arguments) == 1 && arguments[0] != wantedCommand {
		return command{}, command{}, fmt.Errorf("packaged launcher accepts only %q", wantedCommand)
	}

	absoluteConfig, err := filepath.Abs(configPath)
	if err != nil {
		return command{}, command{}, fmt.Errorf("resolve packaged launch config: %w", err)
	}
	releaseRoot := filepath.Dir(filepath.Dir(absoluteConfig))
	expandRelease := func(value string) string {
		return strings.ReplaceAll(value, "{release_root}", releaseRoot)
	}
	sdkRoot, err := filepath.Abs(expandRelease(config.SDKRoot))
	if err != nil {
		return command{}, command{}, fmt.Errorf("resolve packaged SDK root: %w", err)
	}
	activationEnvironment := config.ActivationRootEnvironment
	if activationEnvironment == "" {
		return command{}, command{}, fmt.Errorf("activation_root_environment is required")
	}
	activationRootValue, found := environmentValue(environment, activationEnvironment)
	if !found || activationRootValue == "" {
		return command{}, command{}, fmt.Errorf("%s is required", activationEnvironment)
	}
	activationRoot, err := filepath.Abs(expandRelease(activationRootValue))
	if err != nil {
		return command{}, command{}, fmt.Errorf("resolve activation root: %w", err)
	}
	expand := func(value string) string {
		value = expandRelease(value)
		value = strings.ReplaceAll(value, "{sdk_root}", sdkRoot)
		return strings.ReplaceAll(value, "{activation_root}", activationRoot)
	}

	activation := command{}
	if len(config.ActivationArgs) > 0 {
		activationArgs := make([]string, len(config.ActivationArgs))
		for index, value := range config.ActivationArgs {
			activationArgs[index] = expand(value)
		}
		activation, err = prepare(activationArgs, environment)
		if err != nil {
			return command{}, command{}, fmt.Errorf("prepare packaged activation: %w", err)
		}
	}

	program := expand(config.Program)
	if err := requireExecutable("packaged runtime program", program); err != nil {
		return command{}, command{}, err
	}
	runtimeValues := make(map[string]string, len(config.RuntimeEnvironment))
	for key, value := range config.RuntimeEnvironment {
		runtimeValues[key] = expand(value)
	}
	loader, err := requiredRuntimeValue(runtimeValues, loaderVariable)
	if err != nil {
		return command{}, command{}, err
	}
	if err := requireExecutable("runtime loader", loader); err != nil {
		return command{}, command{}, err
	}
	if _, err := requiredRuntimeValue(runtimeValues, libraryVariable); err != nil {
		return command{}, command{}, err
	}
	runtimeWrapper := expand(config.RuntimeWrapper)
	if err := requireExecutable("packaged runtime wrapper", runtimeWrapper); err != nil {
		return command{}, command{}, err
	}
	runtimeArgs := []string{runtimeWrapper}
	for _, value := range config.Arguments {
		runtimeArgs = append(runtimeArgs, expand(value))
	}
	replacements := make(map[string]string, len(config.RuntimeEnvironment)+len(config.Environment))
	for key, value := range runtimeValues {
		replacements[key] = value
	}
	for key, value := range config.Environment {
		replacements[key] = expand(value)
	}
	replacements[programVariable] = program
	removals := append([]string{
		"FIPS_MODULE_CONF", "LD_LIBRARY_PATH", "LD_PRELOAD", "OPENSSL_CONF", "OPENSSL_MODULES",
	}, config.UnsetEnvironment...)
	runtimeEnvironment := replaceEnvironment(
		environment,
		replacements,
		removals,
	)
	writableCopies := make([]writableCopy, 0, len(config.WritableCopies))
	for _, configured := range config.WritableCopies {
		source := expand(configured.Source)
		destination := expand(configured.Destination)
		if err := requireRegularFile("writable-copy source", source); err != nil {
			return command{}, command{}, err
		}
		if !pathWithin(activationRoot, destination) {
			return command{}, command{}, fmt.Errorf(
				"writable-copy destination must be below activation root: %s",
				destination,
			)
		}
		writableCopies = append(writableCopies, writableCopy{
			source:      source,
			destination: destination,
		})
	}
	return activation, command{
		executable:     runtimeWrapper,
		arguments:      runtimeArgs,
		environment:    runtimeEnvironment,
		writableCopies: writableCopies,
	}, nil
}

func requiredRuntimeValue(environment map[string]string, name string) (string, error) {
	value := environment[name]
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}

func requireRegularFile(description, path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("read %s %s: %w", description, path, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file: %s", description, path)
	}
	return nil
}

func pathWithin(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != "." && relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func materializeWritableCopies(copies []writableCopy) error {
	for _, copy := range copies {
		contents, err := os.ReadFile(copy.source)
		if err != nil {
			return fmt.Errorf("read writable-copy source %s: %w", copy.source, err)
		}
		if err := os.MkdirAll(filepath.Dir(copy.destination), 0o755); err != nil {
			return fmt.Errorf("create writable-copy directory: %w", err)
		}
		if err := os.WriteFile(copy.destination, contents, 0o600); err != nil {
			return fmt.Errorf("write runtime copy %s: %w", copy.destination, err)
		}
	}
	return nil
}

func environmentValue(environment []string, name string) (string, bool) {
	for index := len(environment) - 1; index >= 0; index-- {
		key, value, found := strings.Cut(environment[index], "=")
		if found && key == name {
			return value, true
		}
	}
	return "", false
}

func requireExecutable(description, path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("read %s %s: %w", description, path, err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("%s is not executable: %s", description, path)
	}
	return nil
}

func ensureOutputParent(arguments []string) error {
	for index, argument := range arguments {
		if argument != "-out" {
			continue
		}
		if index+1 >= len(arguments) || arguments[index+1] == "" {
			return fmt.Errorf("fipsinstall -out requires a path")
		}
		if err := os.MkdirAll(filepath.Dir(arguments[index+1]), 0o755); err != nil {
			return fmt.Errorf("create activation output directory: %w", err)
		}
		return nil
	}
	return fmt.Errorf("fipsinstall requires a declared -out path")
}

func prepare(arguments, environment []string) (command, error) {
	if len(arguments) < 3 || arguments[0] != "--sdk-root" {
		return command{}, fmt.Errorf("usage: crypto_activation --sdk-root ROOT fipsinstall [arguments]")
	}
	if arguments[2] != "fipsinstall" {
		return command{}, fmt.Errorf("unsupported OpenSSL activation command %q", arguments[2])
	}

	root, err := filepath.Abs(arguments[1])
	if err != nil {
		return command{}, fmt.Errorf("resolve SDK root: %w", err)
	}
	loader := filepath.Join(root, "lib", "ld-runtime.so.1")
	openssl := filepath.Join(root, "bin", "openssl")
	for description, path := range map[string]string{
		"runtime loader":     loader,
		"OpenSSL executable": openssl,
	} {
		info, statErr := os.Stat(path)
		if statErr != nil {
			return command{}, fmt.Errorf("read %s %s: %w", description, path, statErr)
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			return command{}, fmt.Errorf("%s is not executable: %s", description, path)
		}
	}

	opensslArguments := append([]string{openssl}, arguments[2:]...)
	loaderArguments := []string{
		loader,
		"--library-path", filepath.Join(root, "lib"),
	}
	loaderArguments = append(loaderArguments, opensslArguments...)
	executable, executableArguments, err := loaderExecutable(loader, loaderArguments)
	if err != nil {
		return command{}, err
	}

	return command{
		executable: executable,
		arguments:  executableArguments,
		environment: replaceEnvironment(environment, map[string]string{
			"OPENSSL_CONF":    "/dev/null",
			"OPENSSL_MODULES": filepath.Join(root, "lib", "ossl-modules"),
		}, []string{"FIPS_MODULE_CONF", "LD_LIBRARY_PATH", "LD_PRELOAD"}),
	}, nil
}

func loaderExecutable(loader string, arguments []string) (string, []string, error) {
	// Plain `go test` builds do not receive the Bazel-owned emulator path and
	// exercise command construction with fixture files rather than ELF loaders.
	if qemuAarch64 == "" {
		return loader, arguments, nil
	}
	binary, err := elf.Open(loader)
	if err != nil {
		return "", nil, fmt.Errorf("inspect runtime loader architecture: %w", err)
	}
	machine := binary.Machine
	if err := binary.Close(); err != nil {
		return "", nil, fmt.Errorf("close runtime loader: %w", err)
	}
	native := elf.EM_NONE
	switch runtime.GOARCH {
	case "amd64":
		native = elf.EM_X86_64
	case "arm64":
		native = elf.EM_AARCH64
	}
	if machine == native {
		return loader, arguments, nil
	}
	if machine != elf.EM_AARCH64 || runtime.GOARCH != "amd64" {
		return "", nil, fmt.Errorf("unsupported execution/SDK architecture pair %s/%s", runtime.GOARCH, machine)
	}
	if qemuAarch64 == "" {
		return "", nil, fmt.Errorf("declared AArch64 emulator path is empty")
	}
	qemu, err := declaredExecutable(qemuAarch64)
	if err != nil {
		return "", nil, err
	}
	qemuArguments := append([]string{qemu, loader}, arguments[1:]...)
	return qemu, qemuArguments, nil
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
		if err := requireExecutable("declared AArch64 emulator", candidate); err == nil {
			return filepath.Abs(candidate)
		}
	}
	return "", fmt.Errorf("declared AArch64 emulator is unavailable: %s", path)
}

func replaceEnvironment(environment []string, replacements map[string]string, removals []string) []string {
	removed := make(map[string]struct{}, len(removals))
	for _, name := range removals {
		removed[name] = struct{}{}
	}
	result := make([]string, 0, len(environment)+len(replacements))
	for _, entry := range environment {
		name, _, found := strings.Cut(entry, "=")
		if !found {
			continue
		}
		if strings.HasPrefix(name, "LD_") {
			continue
		}
		if _, replaced := replacements[name]; replaced {
			continue
		}
		if _, remove := removed[name]; remove {
			continue
		}
		result = append(result, entry)
	}
	for name, value := range replacements {
		result = append(result, name+"="+value)
	}
	return result
}
