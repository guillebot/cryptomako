// Package fusefs exposes an unlocked vault as a cleartext read-only FUSE tree.
package fusefs

import (
	"context"
	"io"
	"path"
	"strings"
	"sync"
	"syscall"

	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// Options for Mount.
type Options struct {
	// AllowOther passes allow_other to the kernel (requires fuse.conf).
	AllowOther bool
}

// Mount mounts session at mountpoint (read-only cleartext). Blocks until unmount
// unless ctx is cancelled.
func Mount(ctx context.Context, mountpoint string, session *vault.Session, opts Options) error {
	root := &dirNode{session: session, clearPath: "/"}
	fuseOpts := &fs.Options{
		MountOptions: fuse.MountOptions{
			FsName:     "cryptomako",
			Name:       "cryptomako",
			AllowOther: opts.AllowOther,
			Options:    []string{"ro"},
		},
	}
	server, err := fs.Mount(mountpoint, root, fuseOpts)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = server.Unmount()
	}()
	server.Wait()
	return nil
}

type dirNode struct {
	fs.Inode
	session   *vault.Session
	clearPath string
}

var _ fs.NodeReaddirer = (*dirNode)(nil)
var _ fs.NodeLookuper = (*dirNode)(nil)
var _ fs.NodeGetattrer = (*dirNode)(nil)

func (d *dirNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	out.Mode = 0555 | fuse.S_IFDIR
	return 0
}

func (d *dirNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	entries, err := d.session.List(d.clearPath, false)
	if err != nil {
		return nil, syscall.EIO
	}
	var list []fuse.DirEntry
	for _, e := range entries {
		mode := uint32(fuse.S_IFREG)
		if e.IsDir {
			mode = fuse.S_IFDIR
		}
		list = append(list, fuse.DirEntry{
			Name: path.Base(e.Name),
			Mode: mode,
		})
	}
	return fs.NewListDirStream(list), 0
}

func (d *dirNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childPath := join(d.clearPath, name)
	entries, err := d.session.List(d.clearPath, false)
	if err != nil {
		return nil, syscall.EIO
	}
	var match *vault.Entry
	for i := range entries {
		if path.Base(entries[i].Name) == name {
			match = &entries[i]
			break
		}
	}
	if match == nil {
		return nil, syscall.ENOENT
	}
	var child fs.InodeEmbedder
	var mode uint32
	if match.IsDir {
		child = &dirNode{session: d.session, clearPath: childPath}
		mode = 0555 | fuse.S_IFDIR
	} else {
		child = &fileNode{session: d.session, clearPath: childPath}
		mode = 0444 | fuse.S_IFREG
	}
	stable := fs.StableAttr{Mode: mode}
	inode := d.NewInode(ctx, child, stable)
	out.Mode = mode
	return inode, 0
}

type fileNode struct {
	fs.Inode
	session   *vault.Session
	clearPath string

	mu   sync.Mutex
	data []byte
	loaded bool
}

var _ fs.NodeOpener = (*fileNode)(nil)
var _ fs.NodeGetattrer = (*fileNode)(nil)
var _ fs.NodeReader = (*fileNode)(nil)

func (f *fileNode) load() syscall.Errno {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.loaded {
		return 0
	}
	r, err := f.session.Open(f.clearPath)
	if err != nil {
		return syscall.EIO
	}
	defer r.Close()
	data, err := io.ReadAll(r)
	if err != nil {
		return syscall.EIO
	}
	f.data = data
	f.loaded = true
	return 0
}

func (f *fileNode) Getattr(ctx context.Context, fh fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if errno := f.load(); errno != 0 {
		return errno
	}
	out.Mode = 0444 | fuse.S_IFREG
	out.Size = uint64(len(f.data))
	return 0
}

func (f *fileNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	if flags&(syscall.O_WRONLY|syscall.O_RDWR|syscall.O_APPEND|syscall.O_CREAT|syscall.O_TRUNC) != 0 {
		return nil, 0, syscall.EROFS
	}
	if errno := f.load(); errno != 0 {
		return nil, 0, errno
	}
	return nil, fuse.FOPEN_KEEP_CACHE, 0
}

func (f *fileNode) Read(ctx context.Context, fh fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if errno := f.load(); errno != 0 {
		return nil, errno
	}
	if off >= int64(len(f.data)) {
		return fuse.ReadResultData(nil), 0
	}
	end := int(off) + len(dest)
	if end > len(f.data) {
		end = len(f.data)
	}
	return fuse.ReadResultData(f.data[off:end]), 0
}

func join(parent, name string) string {
	if parent == "/" {
		return "/" + name
	}
	return strings.TrimSuffix(parent, "/") + "/" + name
}
