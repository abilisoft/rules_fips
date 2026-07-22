package main

import (
	"reflect"
	"testing"
)

func TestAbsoluteFromExecutionRootJoinsDeclaredRelativePath(t *testing.T) {
	t.Parallel()

	got, err := absoluteFromExecutionRoot("bazel-out/bin/clang", "/sandbox/execroot")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/sandbox/execroot/bazel-out/bin/clang" {
		t.Fatalf("absoluteFromExecutionRoot() = %q", got)
	}
}

func TestResolveExecutionRootPaths(t *testing.T) {
	t.Parallel()

	arguments := []string{
		"--sysroot=external/sysroot",
		"-fuse-ld=bazel-out/bin/ld.lld",
		"--gcc-toolchain=external/gcc",
		"-resource-dir=bazel-out/resource",
		"-isystem",
		"external/cxx/include",
		"-Lexternal/gcc/lib",
		"external/compiler-rt.a",
		"-Igenerated",
		"plain",
	}
	want := []string{
		"--sysroot=/sandbox/execroot/external/sysroot",
		"-fuse-ld=/sandbox/execroot/bazel-out/bin/ld.lld",
		"--gcc-toolchain=/sandbox/execroot/external/gcc",
		"-resource-dir=/sandbox/execroot/bazel-out/resource",
		"-isystem",
		"/sandbox/execroot/external/cxx/include",
		"-L/sandbox/execroot/external/gcc/lib",
		"/sandbox/execroot/external/compiler-rt.a",
		"-Igenerated",
		"plain",
	}
	if got := resolveExecutionRootPaths(arguments, "/sandbox/execroot"); !reflect.DeepEqual(got, want) {
		t.Fatalf("resolveExecutionRootPaths() = %q, want %q", got, want)
	}
}
