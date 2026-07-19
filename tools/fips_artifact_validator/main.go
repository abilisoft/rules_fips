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
		return errors.New("usage: fips_artifact_validator <openssl|otp> ...")
	}
	switch args[0] {
	case "openssl":
		return validateOpenSSL(args[1:])
	case "otp":
		return validateOTP(args[1:])
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

func validateOpenSSL(args []string) error {
	if len(args) != 16 {
		return fmt.Errorf("openssl: got %d arguments, want 16", len(args))
	}
	opensslBin, fipsModule, config := absolute(args[0]), absolute(args[1]), absolute(args[2])
	libcrypto, libssl, manifest := absolute(args[3]), absolute(args[4]), absolute(args[5])
	arch, loader, sysroot, readelf := args[6], absolute(args[7]), absolute(args[8]), absolute(args[9])
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
	if err := runMuslCommand(emulator, map[string]string{
		"OPENSSL_CONF":    "/dev/null",
		"OPENSSL_MODULES": modulesDir,
	}, loader, "--library-path", libraryPath, opensslBin, "fipsinstall", "-module", fipsModule, "-out", moduleConfig, "-pedantic"); err != nil {
		return err
	}
	if err := runMuslCommand(emulator, map[string]string{
		"OPENSSL_CONF":     config,
		"OPENSSL_MODULES":  modulesDir,
		"FIPS_MODULE_CONF": moduleConfig,
	}, loader, "--library-path", libraryPath, opensslBin, "list", "-providers", "-verbose"); err != nil {
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

func validateOTP(args []string) error {
	if len(args) != 11 {
		return fmt.Errorf("otp: got %d arguments, want 11", len(args))
	}
	root, backend, loader, libcDir, sysroot := absolute(args[0]), args[1], absolute(args[2]), absolute(args[3]), absolute(args[4])
	emulator := optionalAbsolute(args[5])
	if backend != "openssl" {
		return fmt.Errorf("unsupported OTP crypto backend %q", backend)
	}
	opensslConfig, fipsModule, fipsModuleConfig, stamp := absolute(args[6]), absolute(args[7]), absolute(args[8]), absolute(args[9])
	cryptoVersion := args[10]
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
	environment["OPENSSL_CONF"] = opensslConfig
	environment["OPENSSL_MODULES"] = filepath.Dir(fipsModule)
	environment["FIPS_MODULE_CONF"] = fipsModuleConfig
	commandArgs := []string{"--library-path", libcDir + ":" + sysroot + "/usr/lib", beam, "--", "-root", runtimeRoot, "-bindir", bindir, "-progname", "erl", "--", "-home", work, "--", "-crypto", "fips_mode", "true", "-noshell", "-eval", openSSLEval(cryptoVersion)}
	if err := runMuslCommand(emulator, environment, loader, commandArgs...); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(stamp), 0o755); err != nil {
		return err
	}
	return os.WriteFile(stamp, []byte("OTP_FIPS_VERIFIED backend="+backend+"\n"), 0o644)
}

func openSSLEval(version string) string {
	return fmt.Sprintf(`{ok, _} = application:ensure_all_started(crypto), enabled = crypto:info_fips(), #{link_type := static, fips_provider_available := true, fips_provider_buildinfo := BuildInfo} = crypto:info(), true = string:find(BuildInfo, %q) =/= nomatch, Epmd = filename:join(os:getenv("BINDIR"), "epmd"), Port = open_port({spawn_executable, Epmd}, [{args, ["-help"]}, exit_status, stderr_to_stdout]), Wait = fun Read() -> receive {Port, {data, _}} -> Read(); {Port, {exit_status, _}} -> ok after 10000 -> erlang:error(port_timeout) end end, ok = Wait(), halt(0).`, version)
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

func runMuslCommand(emulator string, extraEnv map[string]string, loader string, args ...string) error {
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
