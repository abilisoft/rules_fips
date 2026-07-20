package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestPrepareRequiresDeclaredSDKAndSanitizesEnvironment(t *testing.T) {
	root := t.TempDir()
	for _, relative := range []string{"lib/ld-musl.so.1", "bin/openssl"} {
		path := filepath.Join(root, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	prepared, err := prepare(
		[]string{"--sdk-root", root, "fipsinstall", "-out", filepath.Join(root, "state.cnf")},
		[]string{
			"LANG=C",
			"OPENSSL_CONF=/host/openssl.cnf",
			"OPENSSL_MODULES=/host/modules",
			"FIPS_MODULE_CONF=/host/fipsmodule.cnf",
			"LD_LIBRARY_PATH=/host/lib",
			"LD_PRELOAD=/host/preload.so",
		},
	)
	if err != nil {
		t.Fatal(err)
	}

	loader := filepath.Join(root, "lib", "ld-musl.so.1")
	if prepared.executable != loader {
		t.Fatalf("executable = %q, want %q", prepared.executable, loader)
	}
	if !slices.Contains(prepared.environment, "OPENSSL_CONF=/dev/null") {
		t.Fatalf("environment did not replace OPENSSL_CONF: %v", prepared.environment)
	}
	if !slices.Contains(prepared.environment, "OPENSSL_MODULES="+filepath.Join(root, "lib", "ossl-modules")) {
		t.Fatalf("environment did not replace OPENSSL_MODULES: %v", prepared.environment)
	}
	for _, entry := range prepared.environment {
		for _, forbidden := range []string{"FIPS_MODULE_CONF=", "LD_LIBRARY_PATH=", "LD_PRELOAD=", "/host/"} {
			if strings.HasPrefix(entry, forbidden) || strings.Contains(entry, forbidden) {
				t.Fatalf("environment retained forbidden value %q: %v", forbidden, prepared.environment)
			}
		}
	}
}

func TestPrepareRejectsArbitraryOpenSSLCommands(t *testing.T) {
	if _, err := prepare([]string{"--sdk-root", t.TempDir(), "version"}, nil); err == nil {
		t.Fatal("prepare accepted a non-activation OpenSSL command")
	}
}

func TestEnsureOutputParentCreatesDeclaredDirectory(t *testing.T) {
	output := filepath.Join(t.TempDir(), "activation", "fipsmodule.cnf")
	if err := ensureOutputParent([]string{"--sdk-root", "sdk", "fipsinstall", "-out", output}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Dir(output))
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() {
		t.Fatalf("activation output parent is not a directory: %s", filepath.Dir(output))
	}
}

func TestEnsureOutputParentRequiresOut(t *testing.T) {
	if err := ensureOutputParent([]string{"--sdk-root", "sdk", "fipsinstall"}); err == nil {
		t.Fatal("activation accepted no declared -out path")
	}
}

func TestPreparePackagedLaunchActivatesBeforeDeclaredRuntime(t *testing.T) {
	releaseRoot := t.TempDir()
	sdkRoot := filepath.Join(releaseRoot, ".rules_elixir_mix", "crypto_sdk")
	for _, relative := range []string{
		"lib/ld-musl.so.1",
		"bin/openssl",
		"lib/ossl-modules/fips.so",
	} {
		path := filepath.Join(sdkRoot, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	program := filepath.Join(releaseRoot, "erts-17.0", "bin", "erlexec")
	if err := os.MkdirAll(filepath.Dir(program), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(program, []byte("fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	sysConfig := filepath.Join(releaseRoot, "releases", "1.0.0", "sys.config")
	if err := os.MkdirAll(filepath.Dir(sysConfig), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sysConfig, []byte("runtime config"), 0o444); err != nil {
		t.Fatal(err)
	}

	config := launchConfiguration{
		Schema:                    1,
		Command:                   "start",
		SDKRoot:                   "{release_root}/.rules_elixir_mix/crypto_sdk",
		ActivationRootEnvironment: "RULES_ELIXIR_MIX_CRYPTO_STATE",
		ActivationArgs: []string{
			"--sdk-root", "{sdk_root}", "fipsinstall",
			"-module", "{sdk_root}/lib/ossl-modules/fips.so",
			"-out", "{activation_root}/fipsmodule.cnf",
		},
		RuntimeEnvironment: map[string]string{
			"FIPS_MODULE_CONF": "{activation_root}/fipsmodule.cnf",
			"OPENSSL_CONF":     "{sdk_root}/ssl/openssl.cnf",
			"OPENSSL_MODULES":  "{sdk_root}/lib/ossl-modules",
		},
		Program:   "{release_root}/erts-17.0/bin/erlexec",
		Arguments: []string{"-crypto", "fips_mode", "true"},
		Environment: map[string]string{
			"ROOTDIR": "{release_root}",
		},
		WritableCopies: []writableCopyConfiguration{{
			Source:      "{release_root}/releases/1.0.0/sys.config",
			Destination: "{activation_root}/sys.config",
		}},
	}
	contents, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(releaseRoot, "bin", "app"+launchConfigSuffix)
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(releaseRoot, "state")
	activation, runtime, err := preparePackagedLaunch(
		configPath,
		[]string{"start"},
		[]string{
			"RULES_ELIXIR_MIX_CRYPTO_STATE=" + state,
			"OPENSSL_CONF=/host/openssl.cnf",
			"LD_LIBRARY_PATH=/host/lib",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if activation.executable != filepath.Join(sdkRoot, "lib", "ld-musl.so.1") {
		t.Fatalf("activation executable = %q", activation.executable)
	}
	if !slices.Contains(activation.arguments, filepath.Join(state, "fipsmodule.cnf")) {
		t.Fatalf("activation arguments did not expand state: %v", activation.arguments)
	}
	if runtime.executable != filepath.Join(sdkRoot, "lib", "ld-musl.so.1") {
		t.Fatalf("runtime executable = %q", runtime.executable)
	}
	if !slices.Contains(runtime.arguments, program) {
		t.Fatalf("runtime arguments did not select release program: %v", runtime.arguments)
	}
	for _, expected := range []string{
		"FIPS_MODULE_CONF=" + filepath.Join(state, "fipsmodule.cnf"),
		"ROOTDIR=" + releaseRoot,
	} {
		if !slices.Contains(runtime.environment, expected) {
			t.Fatalf("runtime environment missing %q: %v", expected, runtime.environment)
		}
	}
	for _, entry := range runtime.environment {
		if strings.Contains(entry, "/host/") {
			t.Fatalf("runtime retained ambient host path: %v", runtime.environment)
		}
	}
	if err := materializeWritableCopies(runtime.writableCopies); err != nil {
		t.Fatal(err)
	}
	contents, err = os.ReadFile(filepath.Join(state, "sys.config"))
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "runtime config" {
		t.Fatalf("writable runtime copy = %q", contents)
	}
}

func TestPreparePackagedLaunchRejectsWritableCopyOutsideState(t *testing.T) {
	releaseRoot := t.TempDir()
	config := launchConfiguration{
		Schema:                    1,
		SDKRoot:                   "{release_root}/sdk",
		ActivationRootEnvironment: "RULES_ELIXIR_MIX_CRYPTO_STATE",
		WritableCopies: []writableCopyConfiguration{{
			Source:      "{release_root}/source",
			Destination: "{release_root}/escape",
		}},
	}
	for _, relative := range []string{"sdk/lib/ld-musl.so.1", "sdk/bin/openssl", "program", "source"} {
		path := filepath.Join(releaseRoot, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	config.ActivationArgs = []string{"--sdk-root", "{sdk_root}", "fipsinstall", "-out", "{activation_root}/fipsmodule.cnf"}
	config.Program = "{release_root}/program"
	contents, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(releaseRoot, "bin", "app"+launchConfigSuffix)
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := preparePackagedLaunch(
		configPath,
		[]string{"start"},
		[]string{"RULES_ELIXIR_MIX_CRYPTO_STATE=" + filepath.Join(releaseRoot, "state")},
	); err == nil {
		t.Fatal("packaged launcher accepted a writable copy outside activation state")
	}
}

func TestPreparePackagedLaunchRequiresWritableStateContract(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "bin", "app"+launchConfigSuffix)
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatal(err)
	}
	contents, err := json.Marshal(launchConfiguration{
		Schema:                    1,
		SDKRoot:                   "{release_root}/sdk",
		ActivationRootEnvironment: "RULES_ELIXIR_MIX_CRYPTO_STATE",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := preparePackagedLaunch(configPath, []string{"start"}, nil); err == nil {
		t.Fatal("packaged launcher accepted no activation state")
	}
}
