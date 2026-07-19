package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestElixirArgumentsMatchUpstreamOrdering(t *testing.T) {
	t.Setenv("ELIXIR_ERL_OPTIONS", "")
	arguments, execute, err := elixirArguments(
		"/opt/fips-elixir",
		"/opt/fips-elixir/bin/elixir",
		[]string{"-e", "IO.puts(:ok)"},
	)
	if err != nil {
		t.Fatalf("elixirArguments returned an error: %v", err)
	}
	if !execute {
		t.Fatal("elixirArguments unexpectedly skipped execution")
	}
	want := []string{
		"-noshell",
		"-elixir_root", "/opt/fips-elixir/lib/elixir/lib",
		"-pa", "/opt/fips-elixir/lib/elixir/lib/elixir/ebin",
		"-s", "elixir", "start_cli",
		"-extra", "-e", "IO.puts(:ok)",
	}
	if !reflect.DeepEqual(arguments, want) {
		t.Fatalf("unexpected arguments:\n got: %#v\nwant: %#v", arguments, want)
	}
}

func TestInsertFIPSBootRunsBeforeElixir(t *testing.T) {
	arguments := []string{
		"-noshell",
		"-s", "elixir", "start_cli",
		"-extra", "-e", "IO.puts(:ok)",
	}
	want := []string{
		"-noshell",
		"-pa", "/opt/fips-elixir/lib/fips_boot/ebin",
		"-crypto", "fips_mode", "true",
		"-s", "fips_boot", "verify",
		"-s", "elixir", "start_cli",
		"-extra", "-e", "IO.puts(:ok)",
	}
	got := insertFIPSBoot(arguments, "/opt/fips-elixir", "fips_boot")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected FIPS boot arguments:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestRemoveErlFlagEnvironment(t *testing.T) {
	environment := []string{
		"PATH=/bin",
		"ERL_AFLAGS=-crypto fips_mode false",
		"ERL_FLAGS=-s malicious start",
		"ERL_ZFLAGS=+S 1",
		"ERL_OTP29_FLAGS=-extra bypass",
		"ELIXIR_ERL_OPTIONS=+S 2",
	}
	want := []string{"PATH=/bin", "ELIXIR_ERL_OPTIONS=+S 2"}
	got := removeErlFlagEnvironment(environment)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected environment:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestMuslLoaderFindsRelocatedExecutable(t *testing.T) {
	root := t.TempDir()
	lib := filepath.Join(root, "lib")
	if err := os.Mkdir(lib, 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(lib, "ld-musl-x86_64.so.1")
	if err := os.WriteFile(want, []byte("loader"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := muslLoader(root)
	if err != nil {
		t.Fatalf("muslLoader returned an error: %v", err)
	}
	if got != want {
		t.Fatalf("unexpected loader: got %q, want %q", got, want)
	}
}

func TestRuntimeRootFollowsLauncherSymlink(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(bin, "elixir")
	if err := os.WriteFile(launcher, []byte("launcher"), 0o755); err != nil {
		t.Fatal(err)
	}
	mix := filepath.Join(bin, "mix")
	if err := os.Symlink("elixir", mix); err != nil {
		t.Fatal(err)
	}

	got, err := runtimeRootFromExecutable(mix)
	if err != nil {
		t.Fatalf("runtimeRootFromExecutable returned an error: %v", err)
	}
	if got != root {
		t.Fatalf("unexpected runtime root: got %q, want %q", got, root)
	}
}

func TestRuntimeRootRejectsMisplacedLauncher(t *testing.T) {
	launcher := filepath.Join(t.TempDir(), "elixir")
	if err := os.WriteFile(launcher, []byte("launcher"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := runtimeRootFromExecutable(launcher); err == nil {
		t.Fatal("runtimeRootFromExecutable accepted a launcher outside bin")
	}
}
