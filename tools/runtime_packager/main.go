package main

import (
	"archive/tar"
	"compress/gzip"
	"debug/elf"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const installPrefix = "opt/fips-elixir"

type config struct {
	outputTar      string
	outputManifest string
	backend        string
	arch           string
	otpVersion     string
	elixirVersion  string
	muslRevision   string
	loaderName     string
	libcName       string
	otpTree        string
	elixirTree     string
	bootBeam       string
	launcher       string
	cryptoManifest string
	overlays       []overlay
}

type overlay struct {
	destination string
	source      string
}

type archiveEntry struct {
	data       []byte
	info       fs.FileInfo
	linkTarget string
	source     string
}

type runtimeManifest struct {
	Schema                       int    `json:"schema"`
	Backend                      string `json:"backend"`
	Arch                         string `json:"arch"`
	OTP                          string `json:"otp"`
	Elixir                       string `json:"elixir"`
	Prefix                       string `json:"prefix"`
	Libc                         string `json:"libc"`
	MuslRevision                 string `json:"musl_revision"`
	CryptoLinkage                string `json:"crypto_linkage"`
	NativeLinkage                string `json:"native_linkage"`
	PackagedELFCount             int    `json:"packaged_elf_count"`
	SharedObjects                int    `json:"shared_objects"`
	OperationalEnvironmentStatus string `json:"operational_environment_status"`
}

func main() {
	cfg, err := parseArgs(os.Args[1:])
	if err != nil {
		fail("%v", err)
	}
	if err := packageRuntime(cfg); err != nil {
		fail("%v", err)
	}
}

func parseArgs(args []string) (config, error) {
	if len(args) < 14 || (len(args)-14)%2 != 0 {
		return config{}, fmt.Errorf("usage: runtime_packager OUTPUT_TAR OUTPUT_MANIFEST BACKEND ARCH OTP_VERSION ELIXIR_VERSION MUSL_REVISION LOADER_NAME LIBC_NAME OTP_TREE ELIXIR_TREE BOOT_BEAM LAUNCHER CRYPTO_MANIFEST [DESTINATION SOURCE]...")
	}
	cfg := config{
		outputTar:      args[0],
		outputManifest: args[1],
		backend:        args[2],
		arch:           args[3],
		otpVersion:     args[4],
		elixirVersion:  args[5],
		muslRevision:   args[6],
		loaderName:     args[7],
		libcName:       args[8],
		otpTree:        args[9],
		elixirTree:     args[10],
		bootBeam:       args[11],
		launcher:       args[12],
		cryptoManifest: args[13],
	}
	if cfg.backend != "openssl" && cfg.backend != "boringssl" {
		return config{}, fmt.Errorf("unsupported backend %q", cfg.backend)
	}
	for index := 14; index < len(args); index += 2 {
		cfg.overlays = append(cfg.overlays, overlay{
			destination: args[index],
			source:      args[index+1],
		})
	}
	return cfg, nil
}

func packageRuntime(cfg config) error {
	entries := make(map[string]archiveEntry)
	if err := addTree(entries, cfg.otpTree, cfg.backend, false); err != nil {
		return fmt.Errorf("add OTP tree: %w", err)
	}
	if err := addTree(entries, cfg.elixirTree, cfg.backend, true); err != nil {
		return fmt.Errorf("add Elixir tree: %w", err)
	}
	if err := addSource(entries, installPrefix+"/lib/fips_boot/ebin/"+filepath.Base(cfg.bootBeam), cfg.bootBeam); err != nil {
		return fmt.Errorf("add FIPS boot module: %w", err)
	}
	if err := addSource(entries, installPrefix+"/bin/elixir", cfg.launcher); err != nil {
		return fmt.Errorf("add FIPS launcher: %w", err)
	}
	for _, name := range []string{"elixirc", "iex", "mix"} {
		if err := addSymlink(entries, installPrefix+"/bin/"+name, "elixir"); err != nil {
			return fmt.Errorf("add %s launcher: %w", name, err)
		}
	}
	if err := addSource(entries, installPrefix+"/FIPS_CRYPTO.json", cfg.cryptoManifest); err != nil {
		return fmt.Errorf("add crypto manifest: %w", err)
	}
	for _, item := range cfg.overlays {
		if err := addSource(entries, item.destination, item.source); err != nil {
			return fmt.Errorf("add runtime overlay %s: %w", item.destination, err)
		}
	}

	elfCount, sharedObjects, err := auditELF(entries, cfg)
	if err != nil {
		return err
	}
	manifest := runtimeManifest{
		Schema:           1,
		Backend:          cfg.backend,
		Arch:             cfg.arch,
		OTP:              cfg.otpVersion,
		Elixir:           cfg.elixirVersion,
		Prefix:           "/opt/fips-elixir",
		Libc:             "musl",
		MuslRevision:     cfg.muslRevision,
		CryptoLinkage:    "static",
		PackagedELFCount: elfCount,
		SharedObjects:    sharedObjects,
	}
	if cfg.backend == "boringssl" {
		manifest.NativeLinkage = "fully-static"
		manifest.OperationalEnvironmentStatus = "not-listed-on-cmvp-5296"
	} else {
		manifest.NativeLinkage = "musl-dynamic-bundled-loader"
		manifest.OperationalEnvironmentStatus = "not-listed-on-cmvp-4985"
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encode runtime manifest: %w", err)
	}
	manifestBytes = append(manifestBytes, '\n')
	if err := os.WriteFile(cfg.outputManifest, manifestBytes, 0o644); err != nil {
		return fmt.Errorf("write runtime manifest: %w", err)
	}
	entries[installPrefix+"/FIPS_RUNTIME.json"] = archiveEntry{data: manifestBytes}
	ensureParentDirectories(entries)
	if err := writeArchive(cfg.outputTar, entries); err != nil {
		return err
	}
	return nil
}

func addTree(entries map[string]archiveEntry, root, backend string, excludeElixirLaunchers bool) error {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("resolve tree root: %w", err)
	}
	return filepath.WalkDir(absRoot, func(source string, dirEntry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fmt.Errorf("walk %s: %w", root, walkErr)
		}
		relative, err := filepath.Rel(absRoot, source)
		if err != nil {
			return fmt.Errorf("resolve path relative to %s: %w", root, err)
		}
		if relative == "." {
			return nil
		}
		destination := filepath.ToSlash(relative)
		if excludeElixirLaunchers && isElixirLauncher(destination) {
			return nil
		}
		if omitted(destination, backend) {
			if dirEntry.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if err := validateDestination(destination); err != nil {
			return err
		}
		info, err := dirEntry.Info()
		if err != nil {
			return fmt.Errorf("stat %s: %w", source, err)
		}
		entry := archiveEntry{info: info, source: source}
		if info.Mode()&os.ModeSymlink != 0 {
			rawTarget, readErr := os.Readlink(source)
			if readErr != nil {
				return fmt.Errorf("read symlink %s: %w", source, readErr)
			}
			entry.linkTarget, err = normalizeSymlink(root, destination, rawTarget)
			if err != nil {
				return err
			}
			if filepath.IsAbs(rawTarget) && symlinkResolvesToSelf(destination, entry.linkTarget) {
				info, err = os.Stat(source)
				if err != nil {
					return fmt.Errorf("dereference Bazel input symlink %s: %w", source, err)
				}
				if !info.Mode().IsRegular() {
					return fmt.Errorf("Bazel input symlink is not a regular file: %s", source)
				}
				entry.info = info
				entry.linkTarget = ""
			}
			if entry.linkTarget != "" {
				if err := validateSymlink(destination, entry.linkTarget); err != nil {
					return err
				}
			}
		}
		if entry.info == nil {
			return fmt.Errorf("package entry has no file information: %s", source)
		}
		if existing, found := entries[destination]; found {
			if existing.info != nil && existing.info.IsDir() && entry.info.IsDir() {
				return nil
			}
			return fmt.Errorf("duplicate package path %s", destination)
		}
		entries[destination] = entry
		return nil
	})
}

func symlinkResolvesToSelf(destination, target string) bool {
	resolved := path.Clean(path.Join(path.Dir(destination), filepath.ToSlash(target)))
	return resolved == destination
}

func isElixirLauncher(destination string) bool {
	switch destination {
	case installPrefix + "/bin/elixir",
		installPrefix + "/bin/elixirc",
		installPrefix + "/bin/iex",
		installPrefix + "/bin/mix":
		return true
	default:
		return false
	}
}

func normalizeSymlink(root, destination, target string) (string, error) {
	if !filepath.IsAbs(target) {
		return target, nil
	}
	rootSuffix := "/" + strings.Trim(filepath.ToSlash(filepath.Clean(root)), "/") + "/"
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		return "", fmt.Errorf("resolve absolute package symlink %s -> %s: %w", destination, target, err)
	}
	targetSlash := filepath.ToSlash(filepath.Clean(resolvedTarget))
	index := strings.LastIndex(targetSlash, rootSuffix)
	if index < 0 {
		return "", fmt.Errorf("absolute package symlink %s -> %s", destination, target)
	}
	treeTarget := strings.TrimPrefix(targetSlash[index+len(rootSuffix):], "/")
	if treeTarget == "" || treeTarget == "." || strings.HasPrefix(treeTarget, "../") {
		return "", fmt.Errorf("absolute package symlink escapes input tree: %s -> %s", destination, target)
	}
	relative, err := filepath.Rel(
		filepath.FromSlash(path.Dir(destination)),
		filepath.FromSlash(treeTarget),
	)
	if err != nil {
		return "", fmt.Errorf("normalize package symlink %s -> %s: %w", destination, target, err)
	}
	return filepath.ToSlash(relative), nil
}

func addSource(entries map[string]archiveEntry, destination, source string) error {
	destination = path.Clean(strings.TrimPrefix(filepath.ToSlash(destination), "/"))
	if err := validateDestination(destination); err != nil {
		return err
	}
	info, err := os.Stat(source)
	if err != nil {
		return fmt.Errorf("stat %s: %w", source, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("overlay source is not a regular file: %s", source)
	}
	entries[destination] = archiveEntry{info: info, source: source}
	return nil
}

func addSymlink(entries map[string]archiveEntry, destination, target string) error {
	if err := validateDestination(destination); err != nil {
		return err
	}
	if err := validateSymlink(destination, target); err != nil {
		return err
	}
	if _, found := entries[destination]; found {
		return fmt.Errorf("duplicate package path %s", destination)
	}
	entries[destination] = archiveEntry{linkTarget: target}
	return nil
}

func omitted(name, backend string) bool {
	base := path.Base(name)
	if strings.HasSuffix(base, ".a") || strings.HasSuffix(base, ".la") {
		return true
	}
	if backend == "boringssl" && (strings.HasSuffix(base, ".so") || strings.Contains(base, ".so.")) {
		return true
	}
	return false
}

func validateDestination(destination string) error {
	clean := path.Clean(destination)
	if clean != destination || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return fmt.Errorf("unsafe package path %q", destination)
	}
	if clean != installPrefix &&
		!strings.HasPrefix(clean, installPrefix+"/") &&
		!strings.HasPrefix(installPrefix, clean+"/") {
		return fmt.Errorf("package path escapes install prefix: %q", destination)
	}
	return nil
}

func validateSymlink(destination, target string) error {
	if filepath.IsAbs(target) {
		return fmt.Errorf("absolute package symlink %s -> %s", destination, target)
	}
	resolved := path.Clean(path.Join(path.Dir(destination), filepath.ToSlash(target)))
	if resolved != installPrefix && !strings.HasPrefix(resolved, installPrefix+"/") {
		return fmt.Errorf("package symlink escapes install prefix: %s -> %s", destination, target)
	}
	return nil
}

func auditELF(entries map[string]archiveEntry, cfg config) (int, int, error) {
	elfCount := 0
	sharedObjects := 0
	for name, entry := range entries {
		if entry.info == nil || !entry.info.Mode().IsRegular() {
			continue
		}
		if strings.HasSuffix(name, ".so") || strings.Contains(path.Base(name), ".so.") {
			sharedObjects++
		}
		binary, err := elf.Open(entry.source)
		if err != nil {
			var formatError *elf.FormatError
			if errors.As(err, &formatError) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				continue
			}
			return 0, 0, fmt.Errorf("inspect ELF %s: %w", name, err)
		}
		elfCount++
		interpreter, err := elfInterpreter(binary)
		if err != nil {
			binary.Close()
			return 0, 0, fmt.Errorf("read ELF interpreter for %s: %w", name, err)
		}
		libraries, err := binary.ImportedLibraries()
		closeErr := binary.Close()
		if err != nil {
			return 0, 0, fmt.Errorf("read ELF dependencies for %s: %w", name, err)
		}
		if closeErr != nil {
			return 0, 0, fmt.Errorf("close ELF %s: %w", name, closeErr)
		}
		if cfg.backend == "boringssl" {
			if interpreter != "" {
				return 0, 0, fmt.Errorf("packaged ELF contains an interpreter: %s -> %s", name, interpreter)
			}
			if len(libraries) != 0 {
				return 0, 0, fmt.Errorf("packaged ELF contains dynamic dependencies: %s -> %s", name, strings.Join(libraries, ", "))
			}
			continue
		}
		if interpreter != "" && interpreter != "/opt/fips-elixir/lib/"+cfg.loaderName {
			return 0, 0, fmt.Errorf("packaged ELF uses an external interpreter: %s -> %s", name, interpreter)
		}
		for _, library := range libraries {
			if library != "libc.so" && library != cfg.libcName {
				return 0, 0, fmt.Errorf("packaged ELF has an unbundled dependency: %s -> %s", name, library)
			}
		}
	}
	if elfCount == 0 {
		return 0, 0, fmt.Errorf("package contains no ELF files")
	}
	if cfg.backend == "boringssl" {
		sharedObjects = 0
	}
	return elfCount, sharedObjects, nil
}

func elfInterpreter(binary *elf.File) (string, error) {
	for _, program := range binary.Progs {
		if program.Type != elf.PT_INTERP {
			continue
		}
		value, err := io.ReadAll(program.Open())
		if err != nil {
			return "", err
		}
		return strings.TrimRight(string(value), "\x00"), nil
	}
	return "", nil
}

func ensureParentDirectories(entries map[string]archiveEntry) {
	for name := range entries {
		for parent := path.Dir(name); parent != "." && parent != "/"; parent = path.Dir(parent) {
			if _, found := entries[parent]; found {
				continue
			}
			entries[parent] = archiveEntry{}
		}
	}
}

func writeArchive(output string, entries map[string]archiveEntry) (resultErr error) {
	file, err := os.Create(output)
	if err != nil {
		return fmt.Errorf("create runtime archive: %w", err)
	}
	defer func() {
		if err := file.Close(); resultErr == nil && err != nil {
			resultErr = fmt.Errorf("close runtime archive: %w", err)
		}
	}()

	gzipWriter := gzip.NewWriter(file)
	gzipWriter.Header.ModTime = time.Unix(0, 0).UTC()
	gzipWriter.Header.OS = 255
	defer func() {
		if err := gzipWriter.Close(); resultErr == nil && err != nil {
			resultErr = fmt.Errorf("close gzip stream: %w", err)
		}
	}()
	tarWriter := tar.NewWriter(gzipWriter)
	defer func() {
		if err := tarWriter.Close(); resultErr == nil && err != nil {
			resultErr = fmt.Errorf("close tar stream: %w", err)
		}
	}()

	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if err := writeEntry(tarWriter, name, entries[name]); err != nil {
			return err
		}
	}
	return nil
}

func writeEntry(writer *tar.Writer, name string, entry archiveEntry) error {
	var header *tar.Header
	if entry.info == nil {
		if entry.linkTarget != "" {
			header = &tar.Header{Name: name, Typeflag: tar.TypeSymlink, Mode: 0o777, Linkname: entry.linkTarget}
		} else if entry.data == nil {
			header = &tar.Header{Name: name + "/", Typeflag: tar.TypeDir, Mode: 0o755}
		} else {
			header = &tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(entry.data))}
		}
	} else {
		var err error
		header, err = tar.FileInfoHeader(entry.info, entry.linkTarget)
		if err != nil {
			return fmt.Errorf("create tar header for %s: %w", name, err)
		}
		header.Name = name
		if entry.info.IsDir() {
			header.Name += "/"
		}
	}
	header.Uid = 0
	header.Gid = 0
	header.Uname = ""
	header.Gname = ""
	header.ModTime = time.Unix(0, 0).UTC()
	header.AccessTime = time.Time{}
	header.ChangeTime = time.Time{}
	header.PAXRecords = nil
	if err := writer.WriteHeader(header); err != nil {
		return fmt.Errorf("write tar header for %s: %w", name, err)
	}
	if entry.data != nil {
		if _, err := writer.Write(entry.data); err != nil {
			return fmt.Errorf("write generated file %s: %w", name, err)
		}
		return nil
	}
	if entry.info == nil || !entry.info.Mode().IsRegular() {
		return nil
	}
	input, err := os.Open(entry.source)
	if err != nil {
		return fmt.Errorf("open %s: %w", entry.source, err)
	}
	_, copyErr := io.Copy(writer, input)
	closeErr := input.Close()
	if copyErr != nil {
		return fmt.Errorf("copy %s: %w", entry.source, copyErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close %s: %w", entry.source, closeErr)
	}
	return nil
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "runtime_packager: "+format+"\n", args...)
	os.Exit(1)
}
