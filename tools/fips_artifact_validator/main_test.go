package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestStageCryptoSDKNormalizesDeclaredRuntime(t *testing.T) {
	root := t.TempDir()
	include := filepath.Join(root, "include")
	if err := os.MkdirAll(include, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixture(t, filepath.Join(include, "openssl.h"), 0o644)
	pkgConfig := filepath.Join(root, "pkgconfig")
	if err := os.MkdirAll(pkgConfig, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixture(t, filepath.Join(pkgConfig, "openssl.pc"), 0o644)
	inputs := make([]string, 0, 7)
	for _, name := range []string{"libcrypto.a", "libssl.a", "openssl", "fips.so", "openssl.cnf", "crypto-activate", "ld-linux.so"} {
		path := filepath.Join(root, name)
		writeFixture(t, path, 0o755)
		inputs = append(inputs, path)
	}
	output := filepath.Join(root, "sdk")
	runtimeOutput := filepath.Join(root, "runtime")
	if err := stageCryptoSDK([]string{
		include,
		pkgConfig,
		inputs[0],
		inputs[1],
		inputs[2],
		inputs[3],
		inputs[4],
		inputs[5],
		output,
		runtimeOutput,
		inputs[6],
		"ld-runtime.so.1",
		"--declared-pkg-config",
		filepath.Join(pkgConfig, "openssl.pc"),
		"--declared-headers",
		filepath.Join(include, "openssl.h"),
	}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		filepath.Join(output, "lib", "ld-runtime.so.1"),
		filepath.Join(output, "lib", "pkgconfig", "openssl.pc"),
		filepath.Join(runtimeOutput, "ld-runtime.so.1"),
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("runtime output %s: %v", path, err)
		}
	}
}

func TestStageCryptoSDKRejectsEscapingRuntimeDestination(t *testing.T) {
	arguments := make([]string, 16)
	arguments[11] = "../loader"
	arguments[12] = "--declared-pkg-config"
	arguments[13] = "pkgconfig/openssl.pc"
	arguments[14] = "--declared-headers"
	arguments[15] = "include/openssl.h"
	if err := stageCryptoSDK(arguments); err == nil {
		t.Fatal("stageCryptoSDK accepted an escaping runtime destination")
	}
}

func TestMergedEnvironmentDoesNotInheritHostState(t *testing.T) {
	t.Setenv("LD_PRELOAD", "/host/injection.so")
	t.Setenv("PATH", "/host/bin")

	environment := mergedEnvironment(map[string]string{"OPENSSL_CONF": "/declared/openssl.cnf"})
	if slices.Contains(environment, "LD_PRELOAD=/host/injection.so") || slices.Contains(environment, "PATH=/host/bin") {
		t.Fatalf("mergedEnvironment inherited host state: %v", environment)
	}
	if !slices.Contains(environment, "OPENSSL_CONF=/declared/openssl.cnf") {
		t.Fatalf("mergedEnvironment omitted declared state: %v", environment)
	}
}

func TestSelectEmulatorUsesQEMUOnlyForAArch64CrossExecution(t *testing.T) {
	t.Parallel()

	for _, arch := range []string{"amd64", "arm64"} {
		got, err := selectEmulator(arch, arch, "/declared/qemu-aarch64")
		if err != nil {
			t.Fatal(err)
		}
		if got != "" {
			t.Fatalf("selectEmulator(%q, %q) = %q, want native execution", arch, arch, got)
		}
	}
	got, err := selectEmulator("amd64", "arm64", "/declared/qemu-aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/declared/qemu-aarch64" {
		t.Fatalf("selectEmulator(amd64, arm64) = %q", got)
	}
	if _, err := selectEmulator("amd64", "arm64", ""); err == nil {
		t.Fatal("selectEmulator accepted an Arm64 cross validation without QEMU")
	}
	if _, err := selectEmulator("arm64", "amd64", "/declared/qemu-aarch64"); err == nil {
		t.Fatal("selectEmulator accepted an unsupported AMD64-on-Arm64 validation")
	}
}

func TestDeclaredRuntimeLibraryRejectsMissingAmbiguousAndAbsoluteInputs(t *testing.T) {
	first := t.TempDir()
	second := t.TempDir()
	writeFixture(t, filepath.Join(first, "libc.so.6"), 0o755)
	resolved, err := declaredRuntimeLibrary("libc.so.6", []string{first})
	if err != nil {
		t.Fatal(err)
	}
	if resolved != filepath.Join(first, "libc.so.6") {
		t.Fatalf("declaredRuntimeLibrary() = %q", resolved)
	}
	if _, err := declaredRuntimeLibrary("libm.so.6", []string{first}); err == nil {
		t.Fatal("declaredRuntimeLibrary accepted a missing library")
	}
	writeFixture(t, filepath.Join(second, "libc.so.6"), 0o755)
	if _, err := declaredRuntimeLibrary("libc.so.6", []string{first, second}); err == nil {
		t.Fatal("declaredRuntimeLibrary accepted an ambiguous library")
	}
	if _, err := declaredRuntimeLibrary("/host/libc.so.6", []string{first}); err == nil {
		t.Fatal("declaredRuntimeLibrary accepted a host-absolute DT_NEEDED entry")
	}
}

func TestValidateELFClosureSetWritesStampForDeclaredProgram(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	stamp := filepath.Join(root, "closure.ok")
	if err := validateELFClosureSet([]string{stamp, root, executable}); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(stamp)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "validated\n" {
		t.Fatalf("closure stamp = %q", contents)
	}
}

func TestValidateELFClosureSetRejectsNonELFProgram(t *testing.T) {
	root := t.TempDir()
	program := filepath.Join(root, "program")
	writeFixture(t, program, 0o755)
	if err := validateELFClosureSet([]string{filepath.Join(root, "closure.ok"), root, program}); err == nil {
		t.Fatal("validateELFClosureSet accepted a non-ELF execution tool")
	}
}

func TestStageRuntimeCopiesDeclaredFiles(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "repository", "ld-runtime.so.1")
	output := filepath.Join(root, "action", "ld-runtime.so.1")
	if err := os.MkdirAll(filepath.Dir(source), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(source, []byte("declared loader"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := stageRuntime([]string{source, output}); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "declared loader" {
		t.Fatalf("staged contents = %q", contents)
	}
	info, err := os.Lstat(output)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o755 {
		t.Fatalf("staged mode = %v, want a copied executable", info.Mode())
	}
}

func TestCopyDeclaredFilesAcceptsBazelMappedInput(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "sandbox", "include")
	physical := filepath.Join(root, "outer-execroot", "include", "openssl", "aes.h")
	logical := filepath.Join(source, "openssl", "aes.h")
	if err := os.MkdirAll(filepath.Dir(physical), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(logical), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixture(t, physical, 0o644)
	if err := os.Symlink(physical, logical); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(root, "destination")
	if err := copyDeclaredFiles(source, destination, []string{logical}); err != nil {
		t.Fatalf("copyDeclaredFiles(): %v", err)
	}
	staged := filepath.Join(destination, "openssl", "aes.h")
	info, err := os.Lstat(staged)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() {
		t.Fatalf("staged mode = %v, want a materialized regular file", info.Mode())
	}
}

func TestCopyDeclaredFilesRejectsPathOutsideTree(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(root, "outside.h")
	writeFixture(t, outside, 0o644)
	if err := copyDeclaredFiles(source, filepath.Join(root, "destination"), []string{outside}); err == nil {
		t.Fatal("copyDeclaredFiles accepted a path outside the declared source tree")
	}
}

func writeFixture(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(filepath.Base(path)), mode); err != nil {
		t.Fatal(err)
	}
}
