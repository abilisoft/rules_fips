package main

import (
	"crypto/sha256"
	"debug/elf"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: fips_artifact_validator <elf-closure|openssl|stage-crypto-sdk|stage-runtime> ...")
	}
	switch args[0] {
	case "elf-closure":
		return validateELFClosureSet(args[1:])
	case "openssl":
		return validateOpenSSL(args[1:])
	case "stage-crypto-sdk":
		return stageCryptoSDK(args[1:])
	case "stage-runtime":
		return stageRuntime(args[1:])
	default:
		return fmt.Errorf("unknown validation mode %q", args[0])
	}
}

func validateELFClosureSet(args []string) error {
	if len(args) < 3 {
		return fmt.Errorf("elf-closure: got %d arguments, want output, library path, and one or more programs", len(args))
	}
	output := absolute(args[0])
	libraryDirectories := strings.Split(absolutePathList(args[1]), string(os.PathListSeparator))
	programs := args[2:]
	for _, program := range programs {
		if err := validateELFClosure(absolute(program), libraryDirectories); err != nil {
			return fmt.Errorf("validate declared execution-tool closure: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return fmt.Errorf("create ELF-closure stamp directory: %w", err)
	}
	return os.WriteFile(output, []byte("validated\n"), 0o644)
}

func stageRuntime(args []string) error {
	if len(args) == 0 || len(args)%2 != 0 {
		return fmt.Errorf("stage-runtime: got %d arguments, want one or more source/output pairs", len(args))
	}
	for index := 0; index < len(args); index += 2 {
		output := absolute(args[index+1])
		if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
			return fmt.Errorf("create runtime output directory: %w", err)
		}
		if err := copyFile(absolute(args[index]), output); err != nil {
			return fmt.Errorf("stage runtime file %s: %w", args[index], err)
		}
	}
	return nil
}

func stageCryptoSDK(args []string) error {
	if len(args) < 11 || (len(args)-9)%2 != 0 {
		return fmt.Errorf("stage-crypto-sdk: got %d arguments, want 9 fixed arguments and one or more runtime source/destination pairs", len(args))
	}
	include, libcrypto, libssl := absolute(args[0]), absolute(args[1]), absolute(args[2])
	openssl, provider, config := absolute(args[3]), absolute(args[4]), absolute(args[5])
	activation, output, runtimeOutput := absolute(args[6]), absolute(args[7]), absolute(args[8])
	runtimeFiles := make([]struct {
		source      string
		destination string
	}, 0, (len(args)-9)/2)
	for index := 9; index < len(args); index += 2 {
		destination := args[index+1]
		if destination == "" || filepath.Base(destination) != destination || destination == "." || destination == ".." {
			return fmt.Errorf("invalid normalized runtime destination %q", destination)
		}
		runtimeFiles = append(runtimeFiles, struct {
			source      string
			destination string
		}{absolute(args[index]), destination})
	}

	if err := os.RemoveAll(output); err != nil {
		return err
	}
	if err := os.RemoveAll(runtimeOutput); err != nil {
		return err
	}
	for _, directory := range []string{
		"bin",
		"include",
		"lib",
		"lib/ossl-modules",
		"ssl",
	} {
		if err := os.MkdirAll(filepath.Join(output, directory), 0o755); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(runtimeOutput, 0o755); err != nil {
		return err
	}
	if err := copyDirectory(include, filepath.Join(output, "include")); err != nil {
		return fmt.Errorf("stage OpenSSL headers: %w", err)
	}
	files := []struct {
		source      string
		destination string
	}{
		{libcrypto, "lib/libcrypto.a"},
		{libssl, "lib/libssl.a"},
		{openssl, "bin/openssl"},
		{provider, "lib/ossl-modules/fips.so"},
		{config, "ssl/openssl.cnf"},
		{activation, "bin/crypto-activate"},
	}
	for _, file := range files {
		if err := copyFile(file.source, filepath.Join(output, file.destination)); err != nil {
			return fmt.Errorf("stage %s: %w", file.destination, err)
		}
	}
	for _, file := range runtimeFiles {
		if err := copyFile(file.source, filepath.Join(runtimeOutput, file.destination)); err != nil {
			return fmt.Errorf("stage runtime payload %s: %w", file.destination, err)
		}
		if err := copyFile(file.source, filepath.Join(output, "lib", file.destination)); err != nil {
			return fmt.Errorf("stage SDK runtime %s: %w", file.destination, err)
		}
	}
	return nil
}

func validateOpenSSL(args []string) error {
	if len(args) != 16 {
		return fmt.Errorf("openssl: got %d arguments, want 16", len(args))
	}
	opensslBin, fipsModule, config := absolute(args[0]), absolute(args[1]), absolute(args[2])
	libcrypto, libssl, manifest := absolute(args[3]), absolute(args[4]), absolute(args[5])
	arch, loader, libraryPath, readelf := args[6], absolute(args[7]), absolutePathList(args[8]), absolute(args[9])
	emulator := optionalAbsolute(args[10])
	certificate, moduleVersion, moduleArchiveSHA := args[11], args[12], args[13]
	coreVersion, coreArchiveSHA := args[14], args[15]
	expectedMachine := map[string]string{
		"amd64": "Advanced Micro Devices X86-64",
		"arm64": "AArch64",
	}[arch]
	if expectedMachine == "" {
		return fmt.Errorf("unsupported architecture %q", arch)
	}
	emulator, err := selectEmulator(runtime.GOARCH, arch, emulator)
	if err != nil {
		return err
	}
	libraryDirectories := strings.Split(libraryPath, string(os.PathListSeparator))
	for _, artifact := range []string{opensslBin, fipsModule} {
		if err := validateELFClosure(artifact, libraryDirectories); err != nil {
			return fmt.Errorf("validate declared runtime closure: %w", err)
		}
	}
	for _, artifact := range []string{opensslBin, fipsModule} {
		header, err := commandOutput(nil, readelf, "-h", artifact)
		if err != nil {
			return err
		}
		if !strings.Contains(header, "Machine:") || !strings.Contains(header, expectedMachine) {
			return fmt.Errorf("unexpected ELF machine for %s", artifact)
		}
	}

	moduleConfig := manifest + ".module.cnf"
	defer os.Remove(moduleConfig)
	modulesDir := filepath.Dir(fipsModule)
	loaderArguments := []string{}
	if fileExists(filepath.Join(libraryDirectories[0], "libc.so.6")) {
		loaderArguments = append(loaderArguments, "--inhibit-cache")
	}
	loaderArguments = append(loaderArguments, "--library-path", libraryPath)
	if err := runLoaderCommand(emulator, map[string]string{
		"OPENSSL_CONF":    "/dev/null",
		"OPENSSL_MODULES": modulesDir,
	}, loader, append(slices.Clone(loaderArguments), opensslBin, "fipsinstall", "-module", fipsModule, "-out", moduleConfig, "-pedantic")...); err != nil {
		return err
	}
	if err := runLoaderCommand(emulator, map[string]string{
		"OPENSSL_CONF":     config,
		"OPENSSL_MODULES":  modulesDir,
		"FIPS_MODULE_CONF": moduleConfig,
	}, loader, append(slices.Clone(loaderArguments), opensslBin, "list", "-providers", "-verbose")...); err != nil {
		return err
	}

	operationalEnvironmentStatus := "not-asserted"
	if certificate != "none" {
		operationalEnvironmentStatus = "not-listed-on-referenced-certificate"
	}
	return writeJSON(manifest, map[string]any{
		"schema":                         1,
		"backend":                        "openssl",
		"certificate_reference":          certificate,
		"module_name":                    "OpenSSL FIPS Provider",
		"module_version":                 moduleVersion,
		"module_source_archive_sha256":   moduleArchiveSHA,
		"core_version":                   coreVersion,
		"core_source_archive_sha256":     coreArchiveSHA,
		"arch":                           arch,
		"libcrypto_sha256":               mustSHA256(libcrypto),
		"libssl_sha256":                  mustSHA256(libssl),
		"fips_module_sha256":             mustSHA256(fipsModule),
		"linkage":                        "static-core-dynamic-provider",
		"compliance_claim":               "none",
		"evidence_scope":                 "build-and-runtime-checks-only",
		"operational_environment_status": operationalEnvironmentStatus,
		"service_indicator":              "provider-properties-fips=yes",
	})
}

func validateELFClosure(root string, libraryDirectories []string) error {
	seen := map[string]struct{}{}
	queue := []string{root}
	for len(queue) > 0 {
		path := queue[0]
		queue = queue[1:]
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		binary, err := elf.Open(path)
		if err != nil {
			return fmt.Errorf("inspect ELF %s: %w", path, err)
		}
		libraries, err := binary.ImportedLibraries()
		closeErr := binary.Close()
		if err != nil {
			return fmt.Errorf("read ELF dependencies for %s: %w", path, err)
		}
		if closeErr != nil {
			return fmt.Errorf("close ELF %s: %w", path, closeErr)
		}
		for _, library := range libraries {
			resolved, err := declaredRuntimeLibrary(library, libraryDirectories)
			if err != nil {
				return fmt.Errorf("resolve dependency %s of %s: %w", library, path, err)
			}
			queue = append(queue, resolved)
		}
	}
	return nil
}

func declaredRuntimeLibrary(name string, libraryDirectories []string) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || strings.Contains(name, "/") {
		return "", fmt.Errorf("DT_NEEDED entry must be a basename: %q", name)
	}
	matches := []string{}
	for _, directory := range libraryDirectories {
		candidate := filepath.Join(directory, name)
		if fileExists(candidate) {
			matches = append(matches, candidate)
		}
	}
	if len(matches) != 1 {
		return "", fmt.Errorf("expected exactly one declared library, found %d in %v", len(matches), libraryDirectories)
	}
	return matches[0], nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func absolute(path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	resolved, err := filepath.Abs(path)
	if err != nil {
		panic(err)
	}
	return resolved
}

func optionalAbsolute(path string) string {
	if path == "-" {
		return ""
	}
	return absolute(path)
}

func selectEmulator(hostArch, targetArch, emulator string) (string, error) {
	if hostArch == targetArch {
		return "", nil
	}
	if hostArch == "amd64" && targetArch == "arm64" {
		if emulator == "" {
			return "", errors.New("AArch64 validation on AMD64 requires the declared qemu-aarch64 tool")
		}
		return emulator, nil
	}
	return "", fmt.Errorf("unsupported validation execution architecture %s for target %s", hostArch, targetArch)
}

func absolutePathList(paths string) string {
	entries := strings.Split(paths, string(os.PathListSeparator))
	for index, entry := range entries {
		entries[index] = absolute(entry)
	}
	return strings.Join(entries, string(os.PathListSeparator))
}

func runLoaderCommand(emulator string, extraEnv map[string]string, loader string, args ...string) error {
	executable := loader
	if emulator != "" {
		args = append([]string{loader}, args...)
		executable = emulator
	}
	return runCommand(extraEnv, executable, args...)
}

func runCommand(extraEnv map[string]string, name string, args ...string) error {
	command := exec.Command(name, args...)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = mergedEnvironment(extraEnv)
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func commandOutput(extraEnv map[string]string, name string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	command.Env = mergedEnvironment(extraEnv)
	output, err := command.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("%s: %w\n%s", name, err, output)
	}
	return string(output), nil
}

func mergedEnvironment(extra map[string]string) []string {
	values := map[string]string{
		"LANG":              "C",
		"LC_ALL":            "C",
		"SOURCE_DATE_EPOCH": "0",
		"TZ":                "UTC",
	}
	for key, value := range extra {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	environment := make([]string, 0, len(keys))
	for _, key := range keys {
		environment = append(environment, key+"="+values[key])
	}
	return environment
}

func mustSHA256(path string) string {
	file, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		panic(err)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func writeJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	return os.WriteFile(path, encoded, 0o644)
}

func copyDirectory(source, destination string) error {
	resolvedSource, err := filepath.EvalSymlinks(source)
	if err != nil {
		return err
	}
	ancestors := map[string]struct{}{resolvedSource: {}}
	return copyDirectoryWithin(resolvedSource, destination, resolvedSource, ancestors)
}

func copyDirectoryWithin(source, destination, sourceRoot string, ancestors map[string]struct{}) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		sourcePath := filepath.Join(source, entry.Name())
		destinationPath := filepath.Join(destination, entry.Name())
		if entry.Type()&os.ModeSymlink != 0 {
			resolved, err := filepath.EvalSymlinks(sourcePath)
			if err != nil {
				return err
			}
			relative, err := filepath.Rel(sourceRoot, resolved)
			if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				return fmt.Errorf("symlink %s escapes declared source tree", sourcePath)
			}
			info, err := os.Stat(resolved)
			if err != nil {
				return err
			}
			if info.IsDir() {
				if _, found := ancestors[resolved]; found {
					return fmt.Errorf("symlink %s creates a directory cycle", sourcePath)
				}
				if err := os.MkdirAll(destinationPath, 0o755); err != nil {
					return err
				}
				ancestors[resolved] = struct{}{}
				err = copyDirectoryWithin(resolved, destinationPath, sourceRoot, ancestors)
				delete(ancestors, resolved)
				if err != nil {
					return err
				}
				continue
			}
			if err := copyFile(resolved, destinationPath); err != nil {
				return err
			}
			continue
		}
		if entry.IsDir() {
			if err := os.MkdirAll(destinationPath, 0o755); err != nil {
				return err
			}
			if err := copyDirectoryWithin(sourcePath, destinationPath, sourceRoot, ancestors); err != nil {
				return err
			}
			continue
		}
		if err := copyFile(sourcePath, destinationPath); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil {
		return err
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		return err
	}
	return output.Close()
}
