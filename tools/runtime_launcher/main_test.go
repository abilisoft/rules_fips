package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrepareUsesOnlyDeclaredRuntime(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-musl.so.1")
	program := executableFixture(t, root, "bin/.real-erlexec")
	t.Setenv(loaderVariable, loader)
	t.Setenv(libraryVariable, filepath.Join(root, "lib"))
	t.Setenv(programVariable, program)

	prepared, err := prepare([]string{"-noshell", "/proc/self/cwd/bazel-out/config"}, []string{
		"LANG=C",
		"LD_LIBRARY_PATH=/host/lib",
		"LD_PRELOAD=/host/preload.so",
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Join(root, "lib"),
		programVariable + "=" + program,
	})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.executable != loader {
		t.Fatalf("executable = %q, want %q", prepared.executable, loader)
	}
	wantPrefix := []string{loader, "--library-path", filepath.Join(root, "lib"), "--argv0", os.Args[0], program}
	for index, value := range wantPrefix {
		if prepared.arguments[index] != value {
			t.Fatalf("argument %d = %q, want %q", index, prepared.arguments[index], value)
		}
	}
	wantConfig := filepath.Join(mustWorkingDirectory(t), "bazel-out/config")
	if prepared.arguments[len(wantPrefix)+1] != wantConfig {
		t.Fatalf("resolved config argument = %q, want %q", prepared.arguments[len(wantPrefix)+1], wantConfig)
	}
	for _, entry := range prepared.environment {
		if strings.HasPrefix(entry, "LD_") {
			t.Fatalf("environment retained dynamic-loader injection state: %v", prepared.environment)
		}
	}
	for _, prefix := range []string{loaderVariable + "=", libraryVariable + "=", programVariable + "="} {
		if !containsPrefix(prepared.environment, prefix) {
			t.Fatalf("environment discarded recursive-launch state %q: %v", prefix, prepared.environment)
		}
	}
}

func mustWorkingDirectory(t *testing.T) string {
	t.Helper()
	workingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return workingDirectory
}

func containsPrefix(values []string, prefix string) bool {
	for _, value := range values {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}

func TestWithEnvironmentCarriesResolvedEmulatorToChildren(t *testing.T) {
	got := withEnvironment(
		[]string{"LANG=C", qemuVariable + "=relative/qemu"},
		qemuVariable,
		"/declared/qemu-aarch64",
	)
	if !containsPrefix(got, qemuVariable+"=/declared/qemu-aarch64") {
		t.Fatalf("environment did not carry resolved emulator: %v", got)
	}
	if containsPrefix(got, qemuVariable+"=relative/qemu") {
		t.Fatalf("environment retained unresolved emulator: %v", got)
	}
}

func TestPrepareRequiresExecutableProgram(t *testing.T) {
	root := t.TempDir()
	t.Setenv(loaderVariable, executableFixture(t, root, "lib/ld-musl.so.1"))
	t.Setenv(libraryVariable, filepath.Join(root, "lib"))
	t.Setenv(programVariable, filepath.Join(root, "missing"))
	if _, err := prepare(nil, nil); err == nil {
		t.Fatal("prepare accepted a missing runtime program")
	}
}

func TestSelectedProgramUsesRealSiblingForExecutableIdentity(t *testing.T) {
	root := t.TempDir()
	defaultProgram := executableFixture(t, root, "bin/.real-erlexec")
	erlc := executableFixture(t, root, "bin/.real-erlc")
	if got := selectedProgram(defaultProgram, filepath.Join(root, "tools/erlc")); got != erlc {
		t.Fatalf("selected program = %q, want %q", got, erlc)
	}
	if got := selectedProgram(defaultProgram, filepath.Join(root, "tools/erl")); got != defaultProgram {
		t.Fatalf("selected fallback = %q, want %q", got, defaultProgram)
	}
}

func executableFixture(t *testing.T, root, relative string) string {
	t.Helper()
	path := filepath.Join(root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}
