package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	bindir  = "unset"
	rootdir = "unset"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "OTP bootstrap entry point failed: %v\n", err)
		os.Exit(126)
	}
}

func run() error {
	root := os.Getenv("OTP_BOOTSTRAP_ROOT")
	if root == "" {
		return fmt.Errorf("OTP_BOOTSTRAP_ROOT is not set")
	}
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("resolve OTP bootstrap root %q: %w", root, err)
	}

	absoluteBindir := filepath.Join(absoluteRoot, filepath.FromSlash(bindir))
	absoluteRootdir := filepath.Join(absoluteRoot, filepath.FromSlash(rootdir))
	mode := filepath.Base(os.Args[0])
	environment := replaceEnv(os.Environ(), map[string]string{
		"BINDIR":   absoluteBindir,
		"EMU":      "beam",
		"PROGNAME": "erl",
		"ROOTDIR":  absoluteRootdir,
	})

	var executable string
	switch mode {
	case "erl":
		executable = filepath.Join(absoluteBindir, "erlexec")
	case "erlc":
		executable = filepath.Join(absoluteBindir, "erlc")
		absoluteErl, err := siblingEntrypoint("erl")
		if err != nil {
			return err
		}
		environment = replaceEnv(environment, map[string]string{
			"ERLC_EMULATOR": absoluteErl,
		})
	case "escript":
		executable = filepath.Join(absoluteRootdir, "bin/escript")
		absoluteErl, err := siblingEntrypoint("erl")
		if err != nil {
			return err
		}
		environment = replaceEnv(environment, map[string]string{
			"ESCRIPT_EMULATOR": absoluteErl,
		})
	default:
		return fmt.Errorf("entry point must be named erl, erlc, or escript, got %q", mode)
	}

	arguments := append([]string{mode}, os.Args[1:]...)
	if err := syscall.Exec(executable, arguments, environment); err != nil {
		return fmt.Errorf("exec %s: %w", executable, err)
	}
	return nil
}

func siblingEntrypoint(name string) (string, error) {
	entrypoint, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve bootstrap entry point: %w", err)
	}
	sibling := filepath.Join(filepath.Dir(entrypoint), name)
	absoluteSibling, err := filepath.Abs(sibling)
	if err != nil {
		return "", fmt.Errorf("resolve %s entry point %q: %w", name, sibling, err)
	}
	return absoluteSibling, nil
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
