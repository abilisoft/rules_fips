// foreign_build_driver executes unavoidable upstream configure and make phases
// without introducing a host shell at the Bazel action boundary.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

const executionRootPrefix = "/proc/self/cwd/"

type config struct {
	ConfigureArgs []string          `json:"configure_args"`
	Environment   map[string]string `json:"environment"`
	MakeArgs      []string          `json:"make_args"`
	MakeTargets   []string          `json:"make_targets"`
	Outputs       []output          `json:"outputs"`
	Configure     string            `json:"configure"`
	Make          string            `json:"make"`
	Perl          string            `json:"perl"`
	Shell         string            `json:"shell"`
	SourceDir     string            `json:"source_dir"`
	WorkDir       string            `json:"work_dir"`
}

type output struct {
	Destination string `json:"destination"`
	Directory   bool   `json:"directory"`
	Source      string `json:"source"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: foreign_build_driver CONFIG.json")
		os.Exit(2)
	}

	if err := execute(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "foreign build failed: %v\n", err)
		os.Exit(1)
	}
}

func execute(configPath string) (returnedErr error) {
	executionRoot, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getting execution root: %w", err)
	}

	configFile, err := resolvePath(executionRoot, configPath)
	if err != nil {
		return fmt.Errorf("resolving config: %w", err)
	}

	contents, err := os.ReadFile(configFile)
	if err != nil {
		return fmt.Errorf("reading config: %w", err)
	}

	var cfg config
	if err := json.Unmarshal(contents, &cfg); err != nil {
		return fmt.Errorf("decoding config: %w", err)
	}

	paths, err := resolveConfig(executionRoot, cfg)
	if err != nil {
		return err
	}

	if err := resetDirectory(paths.workDir); err != nil {
		return fmt.Errorf("initializing work directory: %w", err)
	}
	defer func() {
		if err := resetDirectory(paths.workDir); err != nil {
			returnedErr = errors.Join(returnedErr, fmt.Errorf("cleaning work directory: %w", err))
		}
	}()

	buildDir := filepath.Join(paths.workDir, "build")
	stageDir := filepath.Join(paths.workDir, "stage")
	homeDir := filepath.Join(paths.workDir, "home")
	tempDir := filepath.Join(paths.workDir, "tmp")
	for _, directory := range []string{buildDir, stageDir, homeDir, tempDir} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return fmt.Errorf("creating build directory: %w", err)
		}
	}

	environment := freezeExecutionRootEnvironment(executionRoot, cfg.Environment)
	environment["DESTDIR"] = stageDir
	environment["HOME"] = homeDir
	environment["MAKE"] = paths.makeTool
	environment["PERL"] = paths.perl
	environment["PWD"] = buildDir
	environment["SHELL"] = paths.shell
	environment["TMPDIR"] = tempDir
	environmentList := sortedEnvironment(environment)

	configureArgs := append([]string{paths.configure}, cfg.ConfigureArgs...)
	if err := runCommand(paths.perl, configureArgs, buildDir, environmentList); err != nil {
		return fmt.Errorf("configuring source: %w", err)
	}

	makeArgs := slices.Clone(cfg.MakeArgs)
	makeArgs = append(makeArgs,
		"DESTDIR="+stageDir,
		"PERL="+paths.perl,
		"SHELL="+paths.shell,
	)
	if len(cfg.MakeTargets) == 0 {
		return errors.New("building source: at least one make target is required")
	}
	for _, target := range cfg.MakeTargets {
		if target == "" {
			return errors.New("building source: make target is empty")
		}
		arguments := slices.Clone(makeArgs)
		arguments = append(arguments, target)
		if err := runCommand(paths.makeTool, arguments, buildDir, environmentList); err != nil {
			return fmt.Errorf("building source target %q: %w", target, err)
		}
	}

	for _, declaredOutput := range paths.outputs {
		source := filepath.Join(stageDir, declaredOutput.source)
		if declaredOutput.directory {
			if err := copyDirectory(source, declaredOutput.destination); err != nil {
				return fmt.Errorf("copying output directory %q: %w", declaredOutput.source, err)
			}
			continue
		}
		if err := copyFile(source, declaredOutput.destination); err != nil {
			return fmt.Errorf("copying output file %q: %w", declaredOutput.source, err)
		}
	}

	return nil
}

type resolvedConfig struct {
	configure string
	makeTool  string
	outputs   []resolvedOutput
	perl      string
	shell     string
	workDir   string
}

type resolvedOutput struct {
	destination string
	directory   bool
	source      string
}

func resolveConfig(executionRoot string, cfg config) (resolvedConfig, error) {
	configure, err := resolvePath(executionRoot, cfg.Configure)
	if err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving Configure: %w", err)
	}
	makeTool, err := resolvePath(executionRoot, cfg.Make)
	if err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving make: %w", err)
	}
	perl, err := resolvePath(executionRoot, cfg.Perl)
	if err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving Perl: %w", err)
	}
	shell, err := resolvePath(executionRoot, cfg.Shell)
	if err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving shell: %w", err)
	}
	workDir, err := resolvePath(executionRoot, cfg.WorkDir)
	if err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving work directory: %w", err)
	}
	if _, err := resolvePath(executionRoot, cfg.SourceDir); err != nil {
		return resolvedConfig{}, fmt.Errorf("resolving source directory: %w", err)
	}

	resolvedOutputs := make([]resolvedOutput, 0, len(cfg.Outputs))
	for _, declaredOutput := range cfg.Outputs {
		if !filepath.IsLocal(declaredOutput.Source) || declaredOutput.Source == "." {
			return resolvedConfig{}, fmt.Errorf("output source must be a package-relative path: %q", declaredOutput.Source)
		}
		destination, err := resolvePath(executionRoot, declaredOutput.Destination)
		if err != nil {
			return resolvedConfig{}, fmt.Errorf("resolving output destination: %w", err)
		}
		resolvedOutputs = append(resolvedOutputs, resolvedOutput{
			destination: destination,
			directory:   declaredOutput.Directory,
			source:      filepath.Clean(declaredOutput.Source),
		})
	}
	if len(resolvedOutputs) == 0 {
		return resolvedConfig{}, errors.New("at least one output is required")
	}

	return resolvedConfig{
		configure: configure,
		makeTool:  makeTool,
		outputs:   resolvedOutputs,
		perl:      perl,
		shell:     shell,
		workDir:   workDir,
	}, nil
}

func resolvePath(executionRoot, path string) (string, error) {
	if path == "" {
		return "", errors.New("path is empty")
	}
	if strings.HasPrefix(path, executionRootPrefix) {
		path = filepath.Join(executionRoot, strings.TrimPrefix(path, executionRootPrefix))
	} else if !filepath.IsAbs(path) {
		path = filepath.Join(executionRoot, path)
	}
	path = filepath.Clean(path)
	relative, err := filepath.Rel(executionRoot, path)
	if err != nil {
		return "", fmt.Errorf("making path relative to execution root: %w", err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path is outside execution root: %q", path)
	}
	return path, nil
}

func runCommand(tool string, args []string, directory string, environment []string) error {
	command := exec.Command(tool, args...)
	command.Dir = directory
	command.Env = environment
	command.Stderr = os.Stderr
	command.Stdout = os.Stdout
	if err := command.Run(); err != nil {
		return fmt.Errorf("running %q: %w", filepath.Base(tool), err)
	}
	return nil
}

func resetDirectory(path string) error {
	if err := os.RemoveAll(path); err != nil {
		return fmt.Errorf("removing old contents: %w", err)
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		return fmt.Errorf("creating empty directory: %w", err)
	}
	return nil
}

func freezeExecutionRootEnvironment(executionRoot string, input map[string]string) map[string]string {
	output := make(map[string]string, len(input)+8)
	replacement := filepath.Clean(executionRoot) + string(filepath.Separator)
	for key, value := range input {
		output[key] = strings.ReplaceAll(value, executionRootPrefix, replacement)
	}
	return output
}

func sortedEnvironment(environment map[string]string) []string {
	keys := make([]string, 0, len(environment))
	for key := range environment {
		keys = append(keys, key)
	}
	slices.Sort(keys)

	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+environment[key])
	}
	return result
}

func copyDirectory(source, destination string) error {
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return fmt.Errorf("creating destination: %w", err)
	}
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fmt.Errorf("walking source: %w", walkErr)
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return fmt.Errorf("making source path relative: %w", err)
		}
		if relative == "." {
			return nil
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				return fmt.Errorf("reading directory mode: %w", err)
			}
			if err := os.MkdirAll(target, info.Mode().Perm()); err != nil {
				return fmt.Errorf("creating directory: %w", err)
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return copySymlink(source, path, target)
		}
		if err := copyFile(path, target); err != nil {
			return err
		}
		return nil
	})
}

func copySymlink(sourceRoot, source, destination string) error {
	target, err := os.Readlink(source)
	if err != nil {
		return fmt.Errorf("reading symlink: %w", err)
	}
	if filepath.IsAbs(target) {
		return fmt.Errorf("absolute symlink is not allowed: %q", target)
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(source), target))
	relative, err := filepath.Rel(sourceRoot, resolved)
	if err != nil {
		return fmt.Errorf("checking symlink target: %w", err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("symlink escapes source tree: %q", target)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("creating symlink parent: %w", err)
	}
	if err := os.Symlink(target, destination); err != nil {
		return fmt.Errorf("creating symlink: %w", err)
	}
	return nil
}

func copyFile(source, destination string) (returnedErr error) {
	input, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("opening source: %w", err)
	}
	defer func() {
		if err := input.Close(); err != nil {
			returnedErr = errors.Join(returnedErr, fmt.Errorf("closing source: %w", err))
		}
	}()

	info, err := input.Stat()
	if err != nil {
		return fmt.Errorf("reading source metadata: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("source is not a regular file: %q", source)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("creating destination parent: %w", err)
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return fmt.Errorf("creating destination: %w", err)
	}
	defer func() {
		if err := output.Close(); err != nil {
			returnedErr = errors.Join(returnedErr, fmt.Errorf("closing destination: %w", err))
		}
	}()

	if _, err := io.Copy(output, input); err != nil {
		return fmt.Errorf("copying contents: %w", err)
	}
	return nil
}
