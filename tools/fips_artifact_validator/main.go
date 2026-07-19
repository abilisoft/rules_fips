package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
		return errors.New("usage: fips_artifact_validator <boringssl|openssl|otp> ...")
	}
	switch args[0] {
	case "boringssl":
		return validateBoringSSL(args[1:])
	case "openssl":
		return validateOpenSSL(args[1:])
	case "otp":
		return validateOTP(args[1:])
	case "stage-boringssl":
		return stageBoringSSL(args[1:])
	case "stage-otp-bootstrap":
		return stageOTPBootstrap(args[1:])
	case "stage-otp-tools":
		return stageOTPTools(args[1:])
	default:
		return fmt.Errorf("unknown validation mode %q", args[0])
	}
}

func stageOTPBootstrap(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("stage-otp-bootstrap: got %d arguments, want 2", len(args))
	}
	buildRoot, installRoot := absolute(args[0]), absolute(args[1])
	if err := os.MkdirAll(filepath.Join(buildRoot, "stage"), 0o755); err != nil {
		return err
	}
	destination := filepath.Join(installRoot, "native")
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}
	return copyDirectory(buildRoot, destination)
}

func stageOTPTools(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("stage-otp-tools: got %d arguments, want 2", len(args))
	}
	source := filepath.Join(absolute(args[0]), "lib/tools/ebin")
	destination := filepath.Join(absolute(args[1]), "tools_ebin")
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}
	return copyDirectory(source, destination)
}

func stageBoringSSL(args []string) error {
	if len(args) != 3 {
		return fmt.Errorf("stage-boringssl: got %d arguments, want 3", len(args))
	}
	sourceRoot := filepath.Dir(absolute(args[0]))
	buildRoot, installRoot := absolute(args[1]), absolute(args[2])
	for _, directory := range []string{filepath.Join(installRoot, "lib"), filepath.Join(installRoot, "include")} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return err
		}
	}
	for _, library := range []string{"libcrypto.a", "libssl.a"} {
		sourceDirectory := strings.TrimPrefix(library, "lib")
		sourceDirectory = strings.TrimSuffix(sourceDirectory, ".a")
		if err := copyFile(
			filepath.Join(buildRoot, sourceDirectory, library),
			filepath.Join(installRoot, "lib", library),
		); err != nil {
			return err
		}
	}
	return copyDirectory(filepath.Join(sourceRoot, "include"), filepath.Join(installRoot, "include"))
}

func validateBoringSSL(args []string) error {
	if len(args) != 13 {
		return fmt.Errorf("boringssl: got %d arguments, want 13", len(args))
	}
	checkerSource, libcrypto, libssl, includeDir := absolute(args[0]), absolute(args[1]), absolute(args[2]), absolute(args[3])
	checker, manifest, arch := absolute(args[4]), absolute(args[5]), args[6]
	cc, readelf, targetTriplet := absolute(args[7]), absolute(args[8]), args[9]
	sysroot, resourceDir, muslRevision := absolute(args[10]), absolute(args[11]), args[12]

	for _, library := range []string{libcrypto, libssl} {
		header, err := commandOutput(nil, readelf, "-h", library)
		if err != nil {
			return err
		}
		if arch == "arm64" {
			if !strings.Contains(header, "Machine:") || !strings.Contains(header, "AArch64") || strings.Contains(header, "X86-64") {
				return fmt.Errorf("%s is not an AArch64 archive", library)
			}
		} else if !strings.Contains(header, "Machine:") || !strings.Contains(header, "X86-64") {
			return fmt.Errorf("%s is not an x86-64 archive", library)
		}
	}

	if err := os.MkdirAll(filepath.Dir(checker), 0o755); err != nil {
		return err
	}
	if err := runCommand(nil, cc,
		"--target="+targetTriplet,
		"--sysroot="+sysroot,
		"-resource-dir="+resourceDir,
		"--rtlib=compiler-rt",
		"-fuse-ld=lld",
		"-O2", "-static",
		"-I"+includeDir,
		checkerSource, libcrypto,
		"-ldl", "-pthread", "-lm", "-o", checker,
	); err != nil {
		return err
	}
	programHeaders, err := commandOutput(nil, readelf, "-l", checker)
	if err != nil {
		return err
	}
	if strings.Contains(programHeaders, "INTERP") {
		return errors.New("BoringCrypto verifier unexpectedly contains an ELF interpreter")
	}
	dynamic, err := commandOutput(nil, readelf, "-d", checker)
	if err != nil && !strings.Contains(dynamic, "There is no dynamic section") {
		return err
	}
	if strings.Contains(dynamic, "NEEDED") {
		return errors.New("BoringCrypto verifier unexpectedly contains a dynamic dependency")
	}
	if err := runCommand(nil, checker); err != nil {
		return err
	}

	return writeJSON(manifest, map[string]any{
		"schema":                         1,
		"backend":                        "boringssl",
		"certificate":                    "CMVP #5296",
		"module_name":                    "BoringCrypto",
		"module_version":                 "2023042800",
		"source_commit":                  "a430310d6563c0734ddafca7731570dfb683dc19",
		"arch":                           arch,
		"libc":                           "musl",
		"musl_revision":                  muslRevision,
		"libcrypto_sha256":               mustSHA256(libcrypto),
		"libssl_sha256":                  mustSHA256(libssl),
		"checker_sha256":                 mustSHA256(checker),
		"linkage":                        "static",
		"cmake":                          "3.27.4",
		"go":                             "1.21.1",
		"ninja":                          "1.11.1",
		"operational_environment_status": "not-listed-on-cmvp-5296",
		"service_indicator":              "per-service",
	})
}

func validateOpenSSL(args []string) error {
	if len(args) != 10 {
		return fmt.Errorf("openssl: got %d arguments, want 10", len(args))
	}
	opensslBin, fipsModule, config := absolute(args[0]), absolute(args[1]), absolute(args[2])
	libcrypto, libssl, manifest := absolute(args[3]), absolute(args[4]), absolute(args[5])
	arch, loader, sysroot, readelf := args[6], absolute(args[7]), absolute(args[8]), absolute(args[9])
	expectedMachine := map[string]string{
		"amd64": "Advanced Micro Devices X86-64",
		"arm64": "AArch64",
	}[arch]
	if expectedMachine == "" {
		return fmt.Errorf("unsupported architecture %q", arch)
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
	libraryPath := sysroot + "/lib:" + sysroot + "/usr/lib"
	if err := runCommand(map[string]string{
		"OPENSSL_CONF":    "/dev/null",
		"OPENSSL_MODULES": modulesDir,
	}, loader, "--library-path", libraryPath, opensslBin, "fipsinstall", "-module", fipsModule, "-out", moduleConfig, "-pedantic"); err != nil {
		return err
	}
	if err := runCommand(map[string]string{
		"OPENSSL_CONF":     config,
		"OPENSSL_MODULES":  modulesDir,
		"FIPS_MODULE_CONF": moduleConfig,
	}, loader, "--library-path", libraryPath, opensslBin, "list", "-providers", "-verbose"); err != nil {
		return err
	}

	return writeJSON(manifest, map[string]any{
		"schema":             1,
		"backend":            "openssl",
		"certificate":        "CMVP #4985",
		"module_name":        "OpenSSL FIPS Provider",
		"module_version":     "3.1.2",
		"core_version":       "3.5.7",
		"arch":               arch,
		"libcrypto_sha256":   mustSHA256(libcrypto),
		"libssl_sha256":      mustSHA256(libssl),
		"fips_module_sha256": mustSHA256(fipsModule),
		"linkage":            "static-core-dynamic-provider",
		"service_indicator":  "provider-properties-fips=yes",
	})
}

func validateOTP(args []string) error {
	if len(args) != 9 {
		return fmt.Errorf("otp: got %d arguments, want 9", len(args))
	}
	root, backend, loader, libcDir, sysroot := absolute(args[0]), args[1], absolute(args[2]), absolute(args[3]), absolute(args[4])
	opensslConfig, fipsModule, fipsModuleConfig, stamp := absolute(args[5]), absolute(args[6]), absolute(args[7]), absolute(args[8])
	runtimeRoot := filepath.Join(root, "opt/fips-elixir/lib/erlang")
	beams, err := filepath.Glob(filepath.Join(runtimeRoot, "erts-*/bin/beam.smp"))
	if err != nil {
		return err
	}
	if len(beams) != 1 {
		return fmt.Errorf("expected exactly one installed beam.smp, found %d", len(beams))
	}
	beam := beams[0]
	info, err := os.Stat(beam)
	if err != nil {
		return err
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("installed beam.smp is not executable: %s", beam)
	}
	bindir := filepath.Dir(beam)
	work := stamp + ".work"
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}
	defer os.RemoveAll(work)
	environment := map[string]string{
		"ROOTDIR":  runtimeRoot,
		"BINDIR":   bindir,
		"PROGNAME": "erl",
		"EMU":      "beam",
	}
	var executable string
	var commandArgs []string
	if backend == "boringssl" {
		executable = beam
		commandArgs = []string{"--", "-root", runtimeRoot, "-bindir", bindir, "-progname", "erl", "--", "-home", work, "--", "-crypto", "fips_mode", "true", "-noshell", "-eval", boringEval}
	} else if backend == "openssl" {
		environment["OPENSSL_CONF"] = opensslConfig
		environment["OPENSSL_MODULES"] = filepath.Dir(fipsModule)
		environment["FIPS_MODULE_CONF"] = fipsModuleConfig
		executable = loader
		commandArgs = []string{"--library-path", libcDir + ":" + sysroot + "/usr/lib", beam, "--", "-root", runtimeRoot, "-bindir", bindir, "-progname", "erl", "--", "-home", work, "--", "-crypto", "fips_mode", "true", "-noshell", "-eval", openSSLEval}
	} else {
		return fmt.Errorf("unsupported OTP crypto backend %q", backend)
	}
	if err := runCommand(environment, executable, commandArgs...); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(stamp), 0o755); err != nil {
		return err
	}
	return os.WriteFile(stamp, []byte("OTP_FIPS_VERIFIED backend="+backend+"\n"), 0o644)
}

const boringEval = `{ok, _} = application:ensure_all_started(crypto), enabled = crypto:info_fips(), #{link_type := static, cryptolib_version_linked := Linked} = crypto:info(), true = string:find(Linked, "BoringSSL") =/= nomatch, false = crypto:enable_fips_mode(false), enabled = crypto:info_fips(), halt(0).`

const openSSLEval = `{ok, _} = application:ensure_all_started(crypto), enabled = crypto:info_fips(), #{link_type := static, fips_provider_available := true, fips_provider_buildinfo := BuildInfo} = crypto:info(), true = string:find(BuildInfo, "3.1.2") =/= nomatch, halt(0).`

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
	environment := os.Environ()
	for key, value := range extra {
		environment = append(environment, key+"="+value)
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
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		sourcePath := filepath.Join(source, entry.Name())
		destinationPath := filepath.Join(destination, entry.Name())
		if entry.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(sourcePath)
			if err != nil {
				return err
			}
			if err := os.Symlink(target, destinationPath); err != nil {
				return err
			}
			continue
		}
		if entry.IsDir() {
			if err := os.MkdirAll(destinationPath, 0o755); err != nil {
				return err
			}
			if err := copyDirectory(sourcePath, destinationPath); err != nil {
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
