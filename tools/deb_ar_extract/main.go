package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const arMagic = "!<arch>\n"

func main() {
	if len(os.Args) != 4 {
		fail("usage: deb_ar_extract DEB OUTPUT_DIRECTORY CMAKE")
	}
	if err := extract(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		fail("%v", err)
	}
}

func extract(debPath, outputPath, cmakePath string) error {
	deb, err := os.Open(debPath)
	if err != nil {
		return err
	}
	defer deb.Close()

	magic := make([]byte, len(arMagic))
	if _, err := io.ReadFull(deb, magic); err != nil {
		return fmt.Errorf("read ar magic: %w", err)
	}
	if string(magic) != arMagic {
		return fmt.Errorf("%s is not a Debian ar archive", debPath)
	}

	if err := os.MkdirAll(outputPath, 0o755); err != nil {
		return err
	}
	archivePath := filepath.Join(outputPath, ".rules_fips_data.tar")
	if err := copyDataMember(deb, archivePath); err != nil {
		return err
	}
	defer os.Remove(archivePath)

	absArchive, err := filepath.Abs(archivePath)
	if err != nil {
		return err
	}
	absCmake, err := filepath.Abs(cmakePath)
	if err != nil {
		return err
	}

	list := exec.Command(absCmake, "-E", "tar", "tf", absArchive)
	list.Dir = outputPath
	listing, err := list.Output()
	if err != nil {
		return fmt.Errorf("list Debian payload: %w", err)
	}
	for _, entry := range bytes.Split(listing, []byte{'\n'}) {
		name := strings.TrimSpace(string(entry))
		if name == "" {
			continue
		}
		clean := filepath.Clean(name)
		if filepath.IsAbs(name) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe Debian payload path %q", name)
		}
	}

	unpack := exec.Command(absCmake, "-E", "tar", "xf", absArchive)
	unpack.Dir = outputPath
	unpack.Stdout = os.Stdout
	unpack.Stderr = os.Stderr
	if err := unpack.Run(); err != nil {
		return fmt.Errorf("extract Debian payload: %w", err)
	}
	if err := pruneExternalSymlinks(outputPath); err != nil {
		return err
	}
	return os.Remove(archivePath)
}

func pruneExternalSymlinks(root string) error {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("resolve output directory: %w", err)
	}
	return filepath.WalkDir(absRoot, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fmt.Errorf("walk extracted payload: %w", walkErr)
		}
		if entry.Type()&os.ModeSymlink == 0 {
			return nil
		}

		target, err := os.Readlink(path)
		if err != nil {
			return fmt.Errorf("read extracted symlink %s: %w", path, err)
		}
		resolved := filepath.Clean(filepath.Join(filepath.Dir(path), target))
		relative, err := filepath.Rel(absRoot, resolved)
		if err != nil {
			return fmt.Errorf("resolve extracted symlink %s: %w", path, err)
		}
		if filepath.IsAbs(target) || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			if err := os.Remove(path); err != nil {
				return fmt.Errorf("remove package-external symlink %s: %w", path, err)
			}
			return nil
		}
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("validate extracted symlink %s: %w", path, err)
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("remove dangling symlink %s: %w", path, err)
		}
		return nil
	})
}

func copyDataMember(deb io.Reader, outputPath string) error {
	header := make([]byte, 60)
	for {
		_, err := io.ReadFull(deb, header)
		if err == io.EOF {
			return fmt.Errorf("Debian archive has no data.tar member")
		}
		if err != nil {
			return fmt.Errorf("read ar header: %w", err)
		}
		if string(header[58:60]) != "`\n" {
			return fmt.Errorf("invalid ar member header")
		}

		name := strings.TrimSuffix(strings.TrimSpace(string(header[:16])), "/")
		size, err := strconv.ParseInt(strings.TrimSpace(string(header[48:58])), 10, 64)
		if err != nil || size < 0 {
			return fmt.Errorf("invalid ar member size for %q", name)
		}
		if strings.HasPrefix(name, "data.tar") {
			output, err := os.OpenFile(outputPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
			if err != nil {
				return err
			}
			_, copyErr := io.CopyN(output, deb, size)
			closeErr := output.Close()
			if copyErr != nil {
				return fmt.Errorf("copy Debian payload: %w", copyErr)
			}
			return closeErr
		}
		if _, err := io.CopyN(io.Discard, deb, size); err != nil {
			return fmt.Errorf("skip ar member %q: %w", name, err)
		}
		if size%2 != 0 {
			if _, err := io.CopyN(io.Discard, deb, 1); err != nil {
				return fmt.Errorf("skip ar padding: %w", err)
			}
		}
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "deb_ar_extract: "+format+"\n", args...)
	os.Exit(1)
}
