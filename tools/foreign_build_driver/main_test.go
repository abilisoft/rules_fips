package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestResolvePath(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	tests := []struct {
		name    string
		path    string
		want    string
		wantErr bool
	}{
		{
			name: "relative path",
			path: "tools/compiler",
			want: filepath.Join(root, "tools/compiler"),
		},
		{
			name: "execution-root path",
			path: executionRootPrefix + "tools/compiler",
			want: filepath.Join(root, "tools/compiler"),
		},
		{
			name:    "parent traversal",
			path:    "../compiler",
			wantErr: true,
		},
		{
			name:    "empty path",
			path:    "",
			wantErr: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := resolvePath(root, test.path)
			if test.wantErr {
				if err == nil {
					t.Fatalf("resolvePath(%q) returned no error", test.path)
				}
				return
			}
			if err != nil {
				t.Fatalf("resolvePath(%q): %v", test.path, err)
			}
			if got != test.want {
				t.Fatalf("resolvePath(%q) = %q, want %q", test.path, got, test.want)
			}
		})
	}
}

func TestSortedEnvironment(t *testing.T) {
	t.Parallel()

	got := sortedEnvironment(map[string]string{
		"ZED":   "last",
		"ALPHA": "first",
	})
	want := []string{"ALPHA=first", "ZED=last"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sortedEnvironment() = %q, want %q", got, want)
	}
}

func TestFreezeExecutionRootEnvironment(t *testing.T) {
	t.Parallel()

	root := filepath.Join(string(filepath.Separator), "declared", "execroot")
	input := map[string]string{
		"CC":     executionRootPrefix + "tools/clang",
		"CFLAGS": "--sysroot=" + executionRootPrefix + "sysroot -I" + executionRootPrefix + "include",
		"LANG":   "C",
	}
	got := freezeExecutionRootEnvironment(root, input)
	want := map[string]string{
		"CC":     filepath.Join(root, "tools/clang"),
		"CFLAGS": "--sysroot=" + filepath.Join(root, "sysroot") + " -I" + filepath.Join(root, "include"),
		"LANG":   "C",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("freezeExecutionRootEnvironment() = %q, want %q", got, want)
	}
	if input["CC"] != executionRootPrefix+"tools/clang" {
		t.Fatalf("freezeExecutionRootEnvironment() mutated its input: %q", input)
	}
}

func TestCopyDirectoryRejectsEscapingSymlink(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../outside", filepath.Join(source, "escape")); err != nil {
		t.Fatal(err)
	}

	if err := copyDirectory(source, destination); err == nil {
		t.Fatal("copyDirectory() accepted a symlink outside the source tree")
	}
}

func TestCopyDirectoryPreservesExecutableMode(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	if err := os.MkdirAll(filepath.Join(source, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	input := filepath.Join(source, "bin", "tool")
	if err := os.WriteFile(input, []byte("tool"), 0o755); err != nil {
		t.Fatal(err)
	}

	if err := copyDirectory(source, destination); err != nil {
		t.Fatalf("copyDirectory(): %v", err)
	}
	info, err := os.Stat(filepath.Join(destination, "bin", "tool"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("copied mode = %o, want 755", info.Mode().Perm())
	}
}
