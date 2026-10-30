package proxmox

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// DefaultSnippetsDir is where the garage NFS export's snippets directory is
// mounted on the machine that runs talosvm. It is the path Proxmox itself
// mounts the storage at on every node, so the two layouts read the same.
const DefaultSnippetsDir = "/mnt/pve/garage/snippets"

// The Proxmox API cannot upload snippets (upload accepts only iso, vztmpl
// and import content), so talosvm writes them as plain files into the
// mounted export, and the nodes read them from their own mount of the same
// export.

// SnippetName is the file name of a VM's network snippet. The separators
// are underscores, which cluster, pool and VM names cannot contain (they are
// DNS labels), so the name says unambiguously which cluster and VM a file
// belongs to: with hyphens, cluster a's VM a-a-cp-1 and cluster a-a's VM
// cp-1 would share a file.
func SnippetName(cluster, vm string) string { return "talosvm_" + cluster + "_" + vm + "-net.yaml" }

// SnippetHeader is the first line of every snippet talosvm writes. A file
// is only overwritten or removed when its first line is exactly the header
// for the cluster and VM its name says, so a file talosvm did not write, or
// wrote for another VM, is refused rather than replaced.
func SnippetHeader(cluster, vm string) string {
	return fmt.Sprintf("# Written by talosvm for cluster %s, VM %s.", cluster, vm)
}

// snippetContent is a VM's snippet file: the header, then the VM's config as
// the Kubernetes layer rendered it.
func snippetContent(cluster, vm, config string) string {
	return SnippetHeader(cluster, vm) + "\n" + config
}

// SnippetVolume is the Proxmox volume ID of a snippet in storage, the value
// cicustom names.
func SnippetVolume(storage, name string) string { return storage + ":snippets/" + name }

// SnippetFileForVolume maps a snippets volume in storage to its file in
// dir, for volumes in that storage only.
func SnippetFileForVolume(dir, storage, volid string) (string, bool) {
	name, ok := strings.CutPrefix(volid, storage+":snippets/")
	if !ok || name == "" || strings.ContainsAny(name, `/\`) || name == "." || name == ".." {
		return "", false
	}
	return filepath.Join(dir, name), true
}

// CheckSnippetsDir checks that dir is a directory, and unless readOnly, that
// a file can be created in it, by creating and removing one. A dry run
// passes readOnly so it writes nothing at all.
func CheckSnippetsDir(dir string, readOnly bool) error {
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("snippets dir: %w (mount the garage export there; see providers/proxmox/README.md)", err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("snippets dir %s is not a directory", dir)
	}
	if readOnly {
		return nil
	}
	f, err := os.CreateTemp(dir, ".talosvm-check-*")
	if err != nil {
		return fmt.Errorf("snippets dir %s is not writable: %w", dir, err)
	}
	f.Close()
	return os.Remove(f.Name())
}

// maxSnippetSize bounds how much of a snippet is read. Network snippets are
// a few hundred bytes; a bigger file is not one.
const maxSnippetSize = 1 << 20

// readSnippet returns a file's content, or "" with ok false when it does not
// exist. Other tenants' snippets are read too, so it trusts nothing about
// the file: it must be a regular file, not a symlink, FIFO or device, which
// could point anywhere or block forever, and at most maxSnippetSize bytes.
func readSnippet(path string) (string, bool, error) {
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if !fi.Mode().IsRegular() {
		return "", false, fmt.Errorf("%s is not a regular file (%s)", path, fi.Mode().Type())
	}
	if fi.Size() > maxSnippetSize {
		return "", false, fmt.Errorf("%s is %d bytes, more than a snippet's %d", path, fi.Size(), maxSnippetSize)
	}
	f, err := os.Open(path)
	if err != nil {
		return "", false, err
	}
	defer f.Close()
	// The file opened must be the one inspected, not something swapped in
	// between.
	if ofi, err := f.Stat(); err != nil || !os.SameFile(fi, ofi) {
		return "", false, fmt.Errorf("%s changed while being read", path)
	}
	b, err := io.ReadAll(io.LimitReader(f, maxSnippetSize+1))
	if err != nil {
		return "", false, err
	}
	if len(b) > maxSnippetSize {
		return "", false, fmt.Errorf("%s is more than a snippet's %d bytes", path, maxSnippetSize)
	}
	return string(b), true, nil
}

// readOwnedSnippet reads one of talosvm's own snippets: a file that is not
// there is fine, and a file that is there must start with header.
func readOwnedSnippet(path, header string) (string, bool, error) {
	text, found, err := readSnippet(path)
	if err != nil || !found {
		return "", found, err
	}
	first, _, _ := strings.Cut(text, "\n")
	if first != header {
		return "", false, fmt.Errorf("refusing to touch %s: its first line is not %q, so talosvm did not write it for this VM", path, header)
	}
	return text, true, nil
}

// writeFileAtomic writes content to path through a temporary file in the
// same directory and a rename, so a node never reads half a snippet. The
// mode is set to 0644 explicitly, whatever the umask: the file belongs to
// the unprivileged user that runs talosvm, and the Proxmox nodes must still
// be able to read it.
func writeFileAtomic(path, content string) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".talosvm-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp) // a no-op after the rename
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
