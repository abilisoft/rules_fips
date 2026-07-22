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
		"LD_AUDIT=/host/audit.so",
		"LD_DEBUG=all",
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
	wantPrefix := []string{loader, "--library-path", filepath.Join(root, "lib"), "--argv0", program, program}
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

func TestPrepareExecutesDeclaredStaticProgramDirectly(t *testing.T) {
	root := t.TempDir()
	program := executableFixture(t, root, "bin/static-test")
	wrapper := executableFixture(t, root, "bin/wrapped-test")
	configuration := strings.Join([]string{
		staticProgramVariable + "=true",
		programVariable + "=" + program,
		fixedArgCountVariable + "=1",
		fixedArgPrefix + "0=--declared",
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv(staticProgramVariable, "false")
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")

	prepared, err := prepare([]string{"--caller"}, []string{"LANG=C"})
	if err != nil {
		t.Fatal(err)
	}
	if !prepared.fullyStatic {
		t.Fatal("prepare did not retain the declared static runtime mode")
	}
	if prepared.executable != program {
		t.Fatalf("executable = %q, want %q", prepared.executable, program)
	}
	want := []string{program, "--declared", "--caller"}
	for index, argument := range want {
		if prepared.arguments[index] != argument {
			t.Fatalf("argument %d = %q, want %q", index, prepared.arguments[index], argument)
		}
	}
}

func TestAbsoluteBeforeChdirResolvesCanonicalExternalRunfile(t *testing.T) {
	root := t.TempDir()
	runfiles := filepath.Join(root, "runfiles")
	loader := executableFixture(t, runfiles, "+http_archive+runtime/lib/ld-runtime.so.1")
	t.Setenv("RUNFILES_DIR", runfiles)
	t.Setenv("TEST_SRCDIR", "")

	got, err := absoluteBeforeChdir("/proc/self/cwd/external/+http_archive+runtime/lib/ld-runtime.so.1")
	if err != nil {
		t.Fatal(err)
	}
	if got != loader {
		t.Fatalf("absoluteBeforeChdir() = %q, want %q", got, loader)
	}
}

func TestAbsoluteBeforeChdirResolvesMainOutputRunfile(t *testing.T) {
	root := t.TempDir()
	runfiles := filepath.Join(root, "runfiles")
	program := executableFixture(t, runfiles, "_main/tools/perl")
	t.Setenv("RUNFILES_DIR", runfiles)
	t.Setenv("TEST_SRCDIR", "")
	t.Setenv("TEST_WORKSPACE", "")

	got, err := absoluteBeforeChdir("/proc/self/cwd/bazel-out/k8-opt-exec/bin/tools/perl")
	if err != nil {
		t.Fatal(err)
	}
	if got != program {
		t.Fatalf("absoluteBeforeChdir() = %q, want %q", got, program)
	}
}

func TestAbsoluteBeforeChdirResolvesNestedStagedExecroot(t *testing.T) {
	root := t.TempDir()
	wrapper := executableFixture(t, root, "manifest/bazel-out/bin/hermetic-ninja")
	loader := executableFixture(t, root, "manifest/bazel-out/runtime/ld-runtime.so.1")
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })

	got, err := absoluteBeforeChdir("/proc/self/cwd/bazel-out/runtime/ld-runtime.so.1")
	if err != nil {
		t.Fatal(err)
	}
	if got != loader {
		t.Fatalf("absoluteBeforeChdir() = %q, want %q", got, loader)
	}
}

func TestAbsolutePathListResolvesEveryRunfile(t *testing.T) {
	root := t.TempDir()
	runfiles := filepath.Join(root, "runfiles")
	first := filepath.Dir(executableFixture(t, runfiles, "+runtime/lib/first.so"))
	second := filepath.Dir(executableFixture(t, runfiles, "+runtime/usr/lib/second.so"))
	t.Setenv("RUNFILES_DIR", runfiles)
	t.Setenv("TEST_SRCDIR", "")

	got, err := absolutePathList(strings.Join([]string{
		"/proc/self/cwd/external/+runtime/lib",
		"/proc/self/cwd/external/+runtime/usr/lib",
	}, string(os.PathListSeparator)))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{first, second}, string(os.PathListSeparator))
	if got != want {
		t.Fatalf("absolutePathList() = %q, want %q", got, want)
	}
}

func TestPrepareResolvesDeclaredPathEnvironmentFromRunfiles(t *testing.T) {
	root := t.TempDir()
	runfiles := filepath.Join(root, "runfiles")
	include := filepath.Join(runfiles, "_main/fips/toolchains/foreign_perl/lib/5.40.1")
	if err := os.MkdirAll(include, 0o755); err != nil {
		t.Fatal(err)
	}
	loader := executableFixture(t, root, "runtime/ld-linux.so.2")
	program := executableFixture(t, root, "runtime/perl")
	wrapper := executableFixture(t, root, "bin/hermetic-perl")
	configuration := strings.Join([]string{
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Dir(loader),
		programVariable + "=" + program,
		"PERL5LIB=/proc/self/cwd/bazel-out/k8-opt-exec/bin/fips/toolchains/foreign_perl/lib/5.40.1",
		pathEnvironmentVariable + "=PERL5LIB",
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv("RUNFILES_DIR", runfiles)
	t.Setenv("TEST_SRCDIR", "")
	t.Setenv("TEST_WORKSPACE", "")
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")
	t.Setenv(pathEnvironmentVariable, "")
	t.Setenv("PERL5LIB", "")

	prepared, err := prepare(nil, []string{"LANG=C"})
	if err != nil {
		t.Fatal(err)
	}
	if !containsPrefix(prepared.environment, "PERL5LIB="+include) {
		t.Fatalf("environment did not resolve the declared Perl include path: %v", prepared.environment)
	}
}

func TestValidEnvironmentName(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"PERL5LIB", "RUNTIME_PATH_2"} {
		if !validEnvironmentName(name) {
			t.Fatalf("validEnvironmentName(%q) = false", name)
		}
	}
	for _, name := range []string{"", "2PATH", "Path", "PATH-LIST"} {
		if validEnvironmentName(name) {
			t.Fatalf("validEnvironmentName(%q) = true", name)
		}
	}
}

func TestRunfilesRootFromPath(t *testing.T) {
	t.Parallel()

	got := runfilesRootFromPath("/tmp/tool.runfiles/_main/bin/tool")
	if got != "/tmp/tool.runfiles" {
		t.Fatalf("runfilesRootFromPath() = %q, want /tmp/tool.runfiles", got)
	}
	if got := runfilesRootFromPath("/tmp/tool"); got != "" {
		t.Fatalf("runfilesRootFromPath() = %q for path without runfiles tree", got)
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

func containsEntry(values []string, entry string) bool {
	for _, value := range values {
		if value == entry {
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

func TestPrepareLoadsDeclaredEscriptSidecar(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-musl.so.1")
	program := executableFixture(t, root, "bin/.real-escript")
	script := executableFixture(t, root, "bin/tool")
	configuration := strings.Join([]string{
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Join(root, "lib"),
		programVariable + "=" + program,
		"OPENSSL_CONF=/proc/self/cwd/sdk/openssl.cnf",
	}, "\n") + "\n"
	if err := os.WriteFile(script+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")

	prepared, err := prepare([]string{script, "--output", "generated"}, []string{"LANG=C"})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.executable != loader {
		t.Fatalf("executable = %q, want %q", prepared.executable, loader)
	}
	if prepared.arguments[5] != program {
		t.Fatalf("program = %q, want %q", prepared.arguments[5], program)
	}
	if prepared.arguments[6] != script {
		t.Fatalf("script = %q, want %q", prepared.arguments[6], script)
	}
	if !containsPrefix(prepared.environment, "OPENSSL_CONF=") {
		t.Fatalf("environment omitted sidecar activation state: %v", prepared.environment)
	}
}

func TestPrepareLoadsDirectToolSidecar(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-linux.so.2")
	program := executableFixture(t, root, "cmake/bin/cmake")
	wrapper := executableFixture(t, root, "bin/hermetic-cmake")
	configuration := strings.Join([]string{
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Join(root, "lib"),
		programVariable + "=" + program,
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")

	prepared, err := prepare([]string{"--version"}, []string{"LANG=C"})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.executable != loader {
		t.Fatalf("executable = %q, want %q", prepared.executable, loader)
	}
	if prepared.arguments[5] != program {
		t.Fatalf("program = %q, want %q", prepared.arguments[5], program)
	}
	if prepared.arguments[6] != "--version" {
		t.Fatalf("argument = %q, want --version", prepared.arguments[6])
	}
}

func TestPreparePrependsDeclaredFixedArguments(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-linux.so.2")
	program := executableFixture(t, root, "python/bin/python3")
	script := executableFixture(t, root, "scripts/generator.py")
	wrapper := executableFixture(t, root, "bin/hermetic-generator")
	configuration := strings.Join([]string{
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Join(root, "lib"),
		programVariable + "=" + program,
		fixedArgCountVariable + "=2",
		fixedArgPrefix + "0=" + script,
		fixedArgPrefix + "1=--strict",
		argv0Variable + "=generator",
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")
	t.Setenv(fixedArgCountVariable, "")

	prepared, err := prepare([]string{"--output", "generated"}, []string{"LANG=C"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{script, "--strict", "--output", "generated"}
	got := prepared.arguments[len(prepared.arguments)-len(want):]
	for index, argument := range want {
		if got[index] != argument {
			t.Fatalf("argument %d = %q, want %q in %v", index, got[index], argument, prepared.arguments)
		}
	}
	if !containsEntry(prepared.environment, fixedArgCountVariable+"=0") {
		t.Fatalf("environment retained fixed arguments for a nested wrapper: %v", prepared.environment)
	}
	if !containsEntry(prepared.environment, argv0Variable+"=") {
		t.Fatalf("environment retained argv0 for a nested wrapper: %v", prepared.environment)
	}
	wantArgv0 := []string{"--argv0", "generator"}
	for index, argument := range wantArgv0 {
		if prepared.arguments[index+3] != argument {
			t.Fatalf("argv0 argument %d = %q, want %q", index, prepared.arguments[index+3], argument)
		}
	}
}

func TestPrepareFindsRuntimeSidecarThroughDeclaredPath(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-linux.so.2")
	program := executableFixture(t, root, "tools/ninja")
	wrapper := executableFixture(t, root, "bin/hermetic-ninja")
	configuration := strings.Join([]string{
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Join(root, "lib"),
		programVariable + "=" + program,
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = filepath.Base(wrapper)
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv("PATH", filepath.Dir(wrapper))
	t.Setenv(loaderVariable, "")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")

	prepared, err := prepare([]string{"--version"}, []string{"PATH=" + filepath.Dir(wrapper)})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.program != program {
		t.Fatalf("program = %q, want %q", prepared.program, program)
	}
}

func TestRuntimeSidecarPathLookupRejectsAmbiguousTools(t *testing.T) {
	first := t.TempDir()
	second := t.TempDir()
	name := "wrapped-tool"
	firstTool := executableFixture(t, first, name)
	executableFixture(t, second, name)
	t.Setenv("PATH", strings.Join([]string{first, second}, string(os.PathListSeparator)))
	if _, err := executableOnDeclaredPath(name); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("ambiguous lookup error = %v", err)
	}

	t.Setenv("PATH", first)
	if got, err := executableOnDeclaredPath(name); err != nil || got != firstTool {
		t.Fatalf("declared PATH lookup = %q, %v; want %q", got, err, firstTool)
	}
}

func TestPrepareUsesCompleteInheritedRuntimeForSidecarlessDeclaredPathTool(t *testing.T) {
	root := t.TempDir()
	loader := executableFixture(t, root, "lib/ld-linux.so.2")
	program := executableFixture(t, root, "tools/erl_child_setup")
	wrapper := executableFixture(t, root, "bin/erl_child_setup")
	originalArgv0 := os.Args[0]
	os.Args[0] = filepath.Base(wrapper)
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv("PATH", filepath.Dir(wrapper))
	t.Setenv(loaderVariable, loader)
	t.Setenv(libraryVariable, filepath.Dir(loader))
	t.Setenv(programVariable, program)

	prepared, err := prepare([]string{"1024"}, []string{
		"PATH=" + filepath.Dir(wrapper),
		loaderVariable + "=" + loader,
		libraryVariable + "=" + filepath.Dir(loader),
		programVariable + "=" + program,
	})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.executable != loader {
		t.Fatalf("executable = %q, want %q", prepared.executable, loader)
	}
	if prepared.program != program {
		t.Fatalf("program = %q, want %q", prepared.program, program)
	}
}

func TestPrepareSidecarOverridesInheritedRuntime(t *testing.T) {
	root := t.TempDir()
	parentLoader := executableFixture(t, root, "parent/lib/ld-linux.so.2")
	parentProgram := executableFixture(t, root, "parent/bin/cmake")
	childLoader := executableFixture(t, root, "child/lib/ld-linux.so.2")
	childProgram := executableFixture(t, root, "child/bin/ninja")
	wrapper := executableFixture(t, root, "bin/hermetic-ninja")
	configuration := strings.Join([]string{
		loaderVariable + "=" + childLoader,
		libraryVariable + "=" + filepath.Dir(childLoader),
		programVariable + "=" + childProgram,
	}, "\n") + "\n"
	if err := os.WriteFile(wrapper+sidecarSuffix, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	originalArgv0 := os.Args[0]
	os.Args[0] = wrapper
	t.Cleanup(func() { os.Args[0] = originalArgv0 })
	t.Setenv(loaderVariable, parentLoader)
	t.Setenv(libraryVariable, filepath.Dir(parentLoader))
	t.Setenv(programVariable, parentProgram)

	prepared, err := prepare([]string{"--version"}, []string{
		loaderVariable + "=" + parentLoader,
		libraryVariable + "=" + filepath.Dir(parentLoader),
		programVariable + "=" + parentProgram,
	})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.executable != childLoader {
		t.Fatalf("executable = %q, want %q", prepared.executable, childLoader)
	}
	if prepared.program != childProgram {
		t.Fatalf("program = %q, want %q", prepared.program, childProgram)
	}
}

func TestPrepareRejectsPartialRuntimeEnvironment(t *testing.T) {
	t.Setenv(loaderVariable, "/declared/loader")
	t.Setenv(libraryVariable, "")
	t.Setenv(programVariable, "")
	if _, err := prepare([]string{"tool"}, nil); err == nil || !strings.Contains(err.Error(), "incomplete") {
		t.Fatalf("prepare error = %v, want incomplete environment failure", err)
	}
}

func TestBooleanEnvironmentRejectsUnknownValues(t *testing.T) {
	t.Setenv(inhibitCacheVariable, "sometimes")
	if _, err := booleanEnvironment(inhibitCacheVariable); err == nil {
		t.Fatal("booleanEnvironment accepted an ambiguous value")
	}
}

func TestDeclaredLibraryRequiresExactlyOnePackagedFile(t *testing.T) {
	first := t.TempDir()
	second := t.TempDir()
	executableFixture(t, first, "libc.so.6")
	resolved, err := declaredLibrary("libc.so.6", []string{first})
	if err != nil {
		t.Fatal(err)
	}
	if resolved != filepath.Join(first, "libc.so.6") {
		t.Fatalf("declaredLibrary() = %q", resolved)
	}
	executableFixture(t, second, "libc.so.6")
	if _, err := declaredLibrary("libc.so.6", []string{first, second}); err == nil {
		t.Fatal("declaredLibrary accepted an ambiguous runtime library")
	}
	if _, err := declaredLibrary("/host/libc.so.6", []string{first}); err == nil {
		t.Fatal("declaredLibrary accepted a host-absolute DT_NEEDED entry")
	}
}

func TestSelectedProgramUsesRealSiblingForExecutableIdentity(t *testing.T) {
	root := t.TempDir()
	defaultProgram := executableFixture(t, root, "erts/bin/.real-erlexec")
	portProgram := executableFixture(t, root, "lib/erl_interface/bin/.real-erl_call")
	invokedAs := filepath.Join(root, "lib/erl_interface/bin/erl_call")
	if got := selectedProgram(defaultProgram, invokedAs); got != portProgram {
		t.Fatalf("selected program = %q, want %q", got, portProgram)
	}
	if got := selectedArgv0("", defaultProgram, portProgram, invokedAs); got != invokedAs {
		t.Fatalf("selected argv0 = %q, want public launcher %q", got, invokedAs)
	}
	if got := selectedProgram(defaultProgram, filepath.Join(root, "tools/erl")); got != defaultProgram {
		t.Fatalf("selected fallback = %q, want %q", got, defaultProgram)
	}
	if got := selectedArgv0("", defaultProgram, defaultProgram, invokedAs); got != defaultProgram {
		t.Fatalf("fallback argv0 = %q, want program %q", got, defaultProgram)
	}
	if got := selectedArgv0("declared-argv0", defaultProgram, portProgram, invokedAs); got != "declared-argv0" {
		t.Fatalf("configured argv0 = %q, want declared override", got)
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
