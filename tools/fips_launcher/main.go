package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	backend       = "unset"
	elixirVersion = "unset"
)

const elixirUsage = `Usage: elixir [options] [.exs file] [data]

General options include -e/--eval, -r, -S, -pa, -pz, --erl, --name,
--sname, --cookie, --no-halt, --short-version, and -v/--version.
Options after the script or -- are passed to the executed code.
`

const iexUsage = `Usage: iex [options] [.exs file] [data]

IEx accepts Elixir options plus --dbg pry, --dot-iex FILE, and --remsh NAME.
`

const elixircUsage = `Usage: elixirc [elixir switches] [compiler switches] [.ex files]

Compiler switches include -o, --ignore-module-conflict, --no-debug-info,
--no-docs, --profile time, --verbose, and --warnings-as-errors.
`

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "FIPS startup check failed: %v\n", err)
		os.Exit(78)
	}
}

func run() error {
	root := os.Getenv("FIPS_ELIXIR_ROOT")
	if root == "" {
		root = "/opt/fips-elixir"
	}
	arguments, execute, err := elixirArguments(root, os.Args[0], os.Args[1:])
	if err != nil {
		return err
	}
	if !execute {
		return nil
	}

	switch backend {
	case "openssl":
		if err := prepareOpenSSL(root); err != nil {
			return err
		}
		arguments = insertFIPSBoot(arguments, root, "fips_boot")
	case "boringssl":
		checker := filepath.Join(root, "bin/boring-fips-check")
		command := exec.Command(checker)
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		if err := command.Run(); err != nil {
			return fmt.Errorf("run BoringCrypto integrity check: %w", err)
		}
		arguments = insertFIPSBoot(arguments, root, "fips_boot_boringssl")
	default:
		return fmt.Errorf("unsupported compiled backend %q", backend)
	}

	return execOTP(root, arguments)
}

func insertFIPSBoot(arguments []string, root, module string) []string {
	insertAt := len(arguments)
	for index := 0; index < len(arguments); index++ {
		if arguments[index] == "-extra" ||
			(arguments[index] == "-s" && index+1 < len(arguments) && arguments[index+1] == "elixir") {
			insertAt = index
			break
		}
	}
	boot := []string{
		"-pa", filepath.Join(root, "lib/fips_boot/ebin"),
		"-crypto", "fips_mode", "true",
		"-s", module, "verify",
	}
	result := make([]string, 0, len(arguments)+len(boot))
	result = append(result, arguments[:insertAt]...)
	result = append(result, boot...)
	result = append(result, arguments[insertAt:]...)
	return result
}

func elixirArguments(root, program string, arguments []string) ([]string, bool, error) {
	switch filepath.Base(program) {
	case "iex":
		if len(arguments) > 0 && (arguments[0] == "-h" || arguments[0] == "--help") {
			fmt.Fprint(os.Stderr, iexUsage)
			return nil, false, nil
		}
		arguments = append([]string{"--no-halt", "--erl", "-user elixir", "+iex"}, arguments...)
	case "elixirc":
		if len(arguments) == 0 || arguments[0] == "-h" || arguments[0] == "--help" {
			fmt.Fprint(os.Stderr, elixircUsage)
			return nil, false, nil
		}
		arguments = append([]string{"+elixirc"}, arguments...)
	case "mix":
		arguments = append([]string{"-e", "Mix.CLI.main()", "--"}, arguments...)
	case "elixir":
	default:
		return nil, false, fmt.Errorf("unsupported Elixir entry point %q", filepath.Base(program))
	}

	if len(arguments) == 0 || (len(arguments) == 1 && (arguments[0] == "-h" || arguments[0] == "--help")) {
		fmt.Fprint(os.Stderr, elixirUsage)
		return nil, false, nil
	}
	if len(arguments) == 1 && arguments[0] == "--short-version" {
		fmt.Fprintln(os.Stdout, elixirVersion)
		return nil, false, nil
	}

	mode := "cli"
	cliArguments := make([]string, 1, len(arguments)+1)
	cliArguments[0] = "-extra"
	erlangArguments := make([]string, 0, len(arguments))
	for index := 0; index < len(arguments); {
		argument := arguments[index]
		switch argument {
		case "+elixirc":
			cliArguments = append(cliArguments, argument)
			index++
		case "+iex":
			mode = "iex"
			cliArguments = append(cliArguments, argument)
			index++
		case "-v", "--no-halt", "--color", "--no-color":
			cliArguments = append(cliArguments, argument)
			index++
		case "-e", "-r", "-pr", "-pa", "-pz", "--eval", "--remsh", "--dot-iex", "--dbg":
			copied, next := copyArguments(arguments, index, 2)
			cliArguments = append(cliArguments, copied...)
			index = next
		case "--rpc-eval":
			copied, next := copyArguments(arguments, index, 3)
			cliArguments = append(cliArguments, copied...)
			index = next
		case "--hidden":
			erlangArguments = append(erlangArguments, "-hidden")
			index++
		case "--logger-otp-reports", "--logger-sasl-reports":
			if index+1 >= len(arguments) {
				return nil, false, fmt.Errorf("%s requires a boolean value", argument)
			}
			value := arguments[index+1]
			if value == "true" || value == "false" {
				key := "handle_otp_reports"
				if argument == "--logger-sasl-reports" {
					key = "handle_sasl_reports"
				}
				erlangArguments = append(erlangArguments, "-logger", key, value)
			}
			index += 2
		case "--erl":
			if index+1 >= len(arguments) {
				return nil, false, fmt.Errorf("--erl requires an argument string")
			}
			parsed, err := splitArgumentString(arguments[index+1])
			if err != nil {
				return nil, false, fmt.Errorf("parse --erl: %w", err)
			}
			erlangArguments = append(erlangArguments, parsed...)
			index += 2
		case "--cookie":
			if index+1 >= len(arguments) {
				return nil, false, fmt.Errorf("--cookie requires a value")
			}
			erlangArguments = append(erlangArguments, "-setcookie", arguments[index+1])
			index += 2
		case "--sname", "--name":
			if index+1 >= len(arguments) {
				return nil, false, fmt.Errorf("%s requires a value", argument)
			}
			erlangArguments = append(erlangArguments, strings.TrimPrefix(argument, "-"), arguments[index+1])
			index += 2
		case "--erl-config", "--vm-args", "--boot":
			if index+1 >= len(arguments) {
				return nil, false, fmt.Errorf("%s requires a value", argument)
			}
			flag := map[string]string{
				"--erl-config": "-config",
				"--vm-args":    "-args_file",
				"--boot":       "-boot",
			}[argument]
			erlangArguments = append(erlangArguments, flag, arguments[index+1])
			index += 2
		case "--boot-var":
			if index+2 >= len(arguments) {
				return nil, false, fmt.Errorf("--boot-var requires a name and value")
			}
			erlangArguments = append(erlangArguments, "-boot_var", arguments[index+1], arguments[index+2])
			index += 3
		case "--pipe-to":
			return nil, false, fmt.Errorf("--pipe-to is unavailable in the shell-free portable launcher")
		default:
			cliArguments = append(cliArguments, arguments[index:]...)
			index = len(arguments)
		}
	}

	result := []string{
		"-noshell",
		"-elixir_root", filepath.Join(root, "lib/elixir/lib"),
		"-pa", filepath.Join(root, "lib/elixir/lib/elixir/ebin"),
	}
	if options := os.Getenv("ELIXIR_ERL_OPTIONS"); options != "" {
		parsed, err := splitArgumentString(options)
		if err != nil {
			return nil, false, fmt.Errorf("parse ELIXIR_ERL_OPTIONS: %w", err)
		}
		result = append(result, parsed...)
	}
	if mode != "iex" {
		result = append(result, "-s", "elixir", "start_cli")
	}
	result = append(result, erlangArguments...)
	result = append(result, cliArguments...)
	return result, true, nil
}

func copyArguments(arguments []string, index, count int) ([]string, int) {
	end := index + count
	if end > len(arguments) {
		end = len(arguments)
	}
	return arguments[index:end], end
}

func splitArgumentString(value string) ([]string, error) {
	var result []string
	var word strings.Builder
	inSingleQuote := false
	inDoubleQuote := false
	escaped := false
	started := false
	flush := func() {
		if started {
			result = append(result, word.String())
			word.Reset()
			started = false
		}
	}
	for _, character := range value {
		if escaped {
			word.WriteRune(character)
			escaped = false
			started = true
			continue
		}
		switch {
		case character == '\\' && !inSingleQuote:
			escaped = true
			started = true
		case character == '\'' && !inDoubleQuote:
			inSingleQuote = !inSingleQuote
			started = true
		case character == '"' && !inSingleQuote:
			inDoubleQuote = !inDoubleQuote
			started = true
		case (character == ' ' || character == '\t' || character == '\n') && !inSingleQuote && !inDoubleQuote:
			flush()
		default:
			word.WriteRune(character)
			started = true
		}
	}
	if escaped || inSingleQuote || inDoubleQuote {
		return nil, fmt.Errorf("unterminated quote or escape")
	}
	flush()
	return result, nil
}

func execOTP(root string, arguments []string) error {
	erlangRoot := filepath.Join(root, "lib/erlang")
	bindirs, err := filepath.Glob(filepath.Join(erlangRoot, "erts-*/bin"))
	if err != nil {
		return fmt.Errorf("locate ERTS bin directory: %w", err)
	}
	if len(bindirs) != 1 {
		return fmt.Errorf("expected exactly one ERTS bin directory, found %d", len(bindirs))
	}
	bindir := bindirs[0]
	erlexec := filepath.Join(bindir, "erlexec")
	if info, err := os.Stat(erlexec); err != nil {
		return fmt.Errorf("read OTP erlexec %s: %w", erlexec, err)
	} else if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("OTP erlexec is not executable: %s", erlexec)
	}
	environment := removeErlFlagEnvironment(os.Environ())
	environment = replaceEnv(environment, map[string]string{
		"BINDIR":   bindir,
		"EMU":      "beam",
		"PROGNAME": "erl",
		"ROOTDIR":  erlangRoot,
	})
	if backend == "openssl" {
		loader, err := muslLoader(root)
		if err != nil {
			return err
		}
		beam := filepath.Join(bindir, "beam.smp")
		if info, err := os.Stat(beam); err != nil {
			return fmt.Errorf("read OTP emulator %s: %w", beam, err)
		} else if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			return fmt.Errorf("OTP emulator is not executable: %s", beam)
		}
		home := os.Getenv("HOME")
		if home == "" {
			home = root
		}
		argv := []string{
			loader,
			"--library-path", filepath.Join(root, "lib"),
			beam,
			"--", "-root", erlangRoot, "-bindir", bindir, "-progname", "erl",
			"--", "-home", home,
			"--",
		}
		argv = append(argv, arguments...)
		return syscall.Exec(loader, argv, environment)
	}
	argv := append([]string{erlexec}, arguments...)
	return syscall.Exec(erlexec, argv, environment)
}

func muslLoader(root string) (string, error) {
	loaders, err := filepath.Glob(filepath.Join(root, "lib/ld-musl-*.so.1"))
	if err != nil {
		return "", fmt.Errorf("locate packaged musl loader: %w", err)
	}
	if len(loaders) != 1 {
		return "", fmt.Errorf("expected exactly one packaged musl loader, found %d", len(loaders))
	}
	if info, err := os.Stat(loaders[0]); err != nil {
		return "", fmt.Errorf("read packaged musl loader %s: %w", loaders[0], err)
	} else if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("packaged musl loader is not executable: %s", loaders[0])
	}
	return loaders[0], nil
}

func removeErlFlagEnvironment(environ []string) []string {
	result := make([]string, 0, len(environ))
	for _, item := range environ {
		name, _, found := strings.Cut(item, "=")
		if !found {
			continue
		}
		if name == "ERL_AFLAGS" || name == "ERL_FLAGS" || name == "ERL_ZFLAGS" ||
			(strings.HasPrefix(name, "ERL_OTP") && strings.HasSuffix(name, "_FLAGS")) {
			continue
		}
		result = append(result, item)
	}
	return result
}

func prepareOpenSSL(root string) error {
	module := filepath.Join(root, "lib/ossl-modules/fips.so")
	if info, err := os.Stat(module); err != nil {
		return fmt.Errorf("read OpenSSL FIPS provider %s: %w", module, err)
	} else if !info.Mode().IsRegular() {
		return fmt.Errorf("OpenSSL FIPS provider is not a regular file: %s", module)
	}

	runtimeDir, err := os.MkdirTemp("", "fips-elixir-")
	if err != nil {
		return fmt.Errorf("create OpenSSL FIPS runtime directory: %w", err)
	}
	config := filepath.Join(runtimeDir, "fipsmodule.cnf")
	openssl := filepath.Join(root, "bin/openssl")
	modules := filepath.Join(root, "lib/ossl-modules")
	loader, err := muslLoader(root)
	if err != nil {
		return err
	}
	command := exec.Command(loader,
		"--library-path", filepath.Join(root, "lib"),
		openssl,
		"fipsinstall",
		"-module", module,
		"-out", config,
		"-pedantic",
	)
	command.Env = replaceEnv(os.Environ(), map[string]string{
		"OPENSSL_CONF":    "/dev/null",
		"OPENSSL_MODULES": modules,
	})
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("install OpenSSL FIPS integrity configuration: %w", err)
	}

	if err := os.Setenv("OPENSSL_CONF", filepath.Join(root, "ssl/openssl-fips.cnf")); err != nil {
		return fmt.Errorf("set OPENSSL_CONF: %w", err)
	}
	if err := os.Setenv("OPENSSL_MODULES", modules); err != nil {
		return fmt.Errorf("set OPENSSL_MODULES: %w", err)
	}
	if err := os.Setenv("FIPS_MODULE_CONF", config); err != nil {
		return fmt.Errorf("set FIPS_MODULE_CONF: %w", err)
	}
	return nil
}

func replaceEnv(environ []string, replacements map[string]string) []string {
	result := make([]string, 0, len(environ)+len(replacements))
	for _, item := range environ {
		name, _, found := strings.Cut(item, "=")
		if found {
			if _, replaced := replacements[name]; replaced {
				continue
			}
		}
		result = append(result, item)
	}
	for name, value := range replacements {
		result = append(result, name+"="+value)
	}
	return result
}
