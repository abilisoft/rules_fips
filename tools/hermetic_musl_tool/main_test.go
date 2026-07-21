package main

import (
	"reflect"
	"testing"
)

func TestResolveExecutionRootMarkers(t *testing.T) {
	t.Parallel()

	arguments := []string{
		"--sysroot=/proc/self/cwd/external/sysroot",
		"-fuse-ld=/proc/self/cwd/bazel-out/bin/ld.lld",
		"plain",
	}
	want := []string{
		"--sysroot=/sandbox/execroot/external/sysroot",
		"-fuse-ld=/sandbox/execroot/bazel-out/bin/ld.lld",
		"plain",
	}
	if got := resolveExecutionRootMarkers(arguments, "/sandbox/execroot"); !reflect.DeepEqual(got, want) {
		t.Fatalf("resolveExecutionRootMarkers() = %q, want %q", got, want)
	}
}
