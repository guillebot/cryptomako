// Package fusefs exposes an unlocked vault as a cleartext FUSE tree.
// Default is read-only; Options.ReadWrite enables create/write/rename/unlink/mkdir
// with fail-closed remote semantics (store Put/Delete must succeed).
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
	// ReadWrite enables create/write/rename/unlink/mkdir. When false, the
	// kernel mount is "ro" and mutating ops return EROFS.
	ReadWrite bool
}

// NewCleartextRoot returns the FUSE root inode embedder for an unlocked session.
// Useful for tests that exercise the tree without a live /dev/fuse mount.
func NewCleartextRoot(session *vault.Session, readWrite bool) fs.InodeEmbedder {
	return &dirNode{session: session, clearPath: "/", rw: readWrite}
}

// Mount mounts session at mountpoint. Blocks until unmount unless ctx is cancelled.
func Mount(ctx context.Context, mountpoint string, session *vault.Session, opts Options) error {
	root := NewCleartextRoot(session, opts.ReadWrite)
	mountOpts := fuse.MountOptions{
		FsName:     "cryptomako",
		Name:       "cryptomako",
		AllowOther: opts.AllowOther,
	}
	if !opts.ReadWrite {
		mountOpts.Options = []string{"ro"}
	}
	fuseOpts := &fs.Options{MountOptions: mountOpts}
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
	rw        bool
}

var _ fs.NodeReaddirer = (*dirNode)(nil)
var _ fs.NodeLookuper = (*dirNode)(nil)
var _ fs.NodeGetattrer = (*dirNode)(nil)
var _ fs.NodeCreater = (*dirNode)(nil)
var _ fs.NodeMkdirer = (*dirNode)(nil)
var _ fs.NodeUnlinker = (*dirNode)(nil)
var _ fs.NodeRmdirer = (*dirNode)(nil)
var _ fs.NodeRenamer = (*dirNode)(nil)

func (d *dirNode) mode() uint32 {
	if d.rw {
		return 0755 | fuse.S_IFDIR
	}
	return 0555 | fuse.S_IFDIR
}

func (d *dirNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	out.Mode = d.mode()
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
		child = &dirNode{session: d.session, clearPath: childPath, rw: d.rw}
		mode = (&dirNode{rw: d.rw}).mode()
	} else {
		fn := &fileNode{session: d.session, clearPath: childPath, rw: d.rw}
		child = fn
		mode = fn.mode()
	}
	stable := fs.StableAttr{Mode: mode}
	inode := d.NewInode(ctx, child, stable)
	out.Mode = mode
	return inode, 0
}

func (d *dirNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	if !d.rw {
		return nil, nil, 0, syscall.EROFS
	}
	childPath := join(d.clearPath, name)
	// Fail-closed: empty ciphertext must land in the store before we report success.
	if err := d.session.PutFile(childPath, nil); err != nil {
		return nil, nil, 0, syscall.EIO
	}
	fn := &fileNode{
		session:   d.session,
		clearPath: childPath,
		rw:        true,
		data:      nil,
		loaded:    true,
	}
	out.Mode = fn.mode()
	inode := d.NewInode(ctx, fn, fs.StableAttr{Mode: out.Mode})
	fh := &openFile{node: fn, data: nil, dirty: false}
	return inode, fh, 0, 0
}

func (d *dirNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if !d.rw {
		return nil, syscall.EROFS
	}
	childPath := join(d.clearPath, name)
	if err := d.session.EnsureDir(childPath); err != nil {
		return nil, syscall.EIO
	}
	child := &dirNode{session: d.session, clearPath: childPath, rw: true}
	out.Mode = child.mode()
	inode := d.NewInode(ctx, child, fs.StableAttr{Mode: out.Mode})
	return inode, 0
}

func (d *dirNode) Unlink(ctx context.Context, name string) syscall.Errno {
	if !d.rw {
		return syscall.EROFS
	}
	childPath := join(d.clearPath, name)
	if err := d.session.DeleteFile(childPath); err != nil {
		return syscall.EIO
	}
	return 0
}

func (d *dirNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	if !d.rw {
		return syscall.EROFS
	}
	childPath := join(d.clearPath, name)
	nErr := d.session.DeletePath(childPath)
	if nErr != nil {
		return syscall.EIO
	}
	return 0
}

func (d *dirNode) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	if !d.rw {
		return syscall.EROFS
	}
	np, ok := newParent.(*dirNode)
	if !ok || !np.rw {
		return syscall.EIO
	}
	oldPath := join(d.clearPath, name)
	newPath := join(np.clearPath, newName)
	if err := d.session.Rename(oldPath, newPath); err != nil {
		return syscall.EIO
	}
	return 0
}

type fileNode struct {
	fs.Inode
	session   *vault.Session
	clearPath string
	rw        bool

	mu     sync.Mutex
	data   []byte
	loaded bool
}

var _ fs.NodeOpener = (*fileNode)(nil)
var _ fs.NodeGetattrer = (*fileNode)(nil)
var _ fs.NodeReader = (*fileNode)(nil)
var _ fs.NodeWriter = (*fileNode)(nil)
var _ fs.NodeFlusher = (*fileNode)(nil)
var _ fs.NodeFsyncer = (*fileNode)(nil)
var _ fs.NodeSetattrer = (*fileNode)(nil)

func (f *fileNode) mode() uint32 {
	if f.rw {
		return 0644 | fuse.S_IFREG
	}
	return 0444 | fuse.S_IFREG
}

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
	if of, ok := fh.(*openFile); ok {
		of.mu.Lock()
		out.Mode = f.mode()
		out.Size = uint64(len(of.data))
		of.mu.Unlock()
		return 0
	}
	if errno := f.load(); errno != 0 {
		return errno
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out.Mode = f.mode()
	out.Size = uint64(len(f.data))
	return 0
}

func (f *fileNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	wantWrite := flags&(syscall.O_WRONLY|syscall.O_RDWR|syscall.O_APPEND|syscall.O_TRUNC) != 0
	if wantWrite && !f.rw {
		return nil, 0, syscall.EROFS
	}
	if errno := f.load(); errno != 0 {
		return nil, 0, errno
	}
	f.mu.Lock()
	data := append([]byte(nil), f.data...)
	f.mu.Unlock()
	of := &openFile{node: f, data: data, dirty: false}
	if flags&syscall.O_TRUNC != 0 && f.rw {
		of.data = nil
		of.dirty = true
		// Fail-closed truncate: push empty object immediately.
		if err := f.session.PutFile(f.clearPath, nil); err != nil {
			return nil, 0, syscall.EIO
		}
		of.dirty = false
		f.mu.Lock()
		f.data = nil
		f.mu.Unlock()
	}
	if !wantWrite {
		return of, fuse.FOPEN_KEEP_CACHE, 0
	}
	return of, 0, 0
}

func (f *fileNode) Read(ctx context.Context, fh fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if of, ok := fh.(*openFile); ok {
		of.mu.Lock()
		defer of.mu.Unlock()
		if off >= int64(len(of.data)) {
			return fuse.ReadResultData(nil), 0
		}
		end := int(off) + len(dest)
		if end > len(of.data) {
			end = len(of.data)
		}
		return fuse.ReadResultData(of.data[off:end]), 0
	}
	if errno := f.load(); errno != 0 {
		return nil, errno
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if off >= int64(len(f.data)) {
		return fuse.ReadResultData(nil), 0
	}
	end := int(off) + len(dest)
	if end > len(f.data) {
		end = len(f.data)
	}
	return fuse.ReadResultData(f.data[off:end]), 0
}

func (f *fileNode) Write(ctx context.Context, fh fs.FileHandle, data []byte, off int64) (uint32, syscall.Errno) {
	if !f.rw {
		return 0, syscall.EROFS
	}
	of, ok := fh.(*openFile)
	if !ok {
		return 0, syscall.EIO
	}
	of.mu.Lock()
	defer of.mu.Unlock()
	end := int(off) + len(data)
	if end > len(of.data) {
		grown := make([]byte, end)
		copy(grown, of.data)
		of.data = grown
	}
	copy(of.data[off:], data)
	of.dirty = true
	return uint32(len(data)), 0
}

func (f *fileNode) Flush(ctx context.Context, fh fs.FileHandle) syscall.Errno {
	return f.commit(fh)
}

func (f *fileNode) Fsync(ctx context.Context, fh fs.FileHandle, flags uint32) syscall.Errno {
	return f.commit(fh)
}

func (f *fileNode) commit(fh fs.FileHandle) syscall.Errno {
	of, ok := fh.(*openFile)
	if !ok {
		return 0
	}
	of.mu.Lock()
	defer of.mu.Unlock()
	if !of.dirty {
		return 0
	}
	// Fail-closed: cleartext write only succeeds after store Put.
	if err := f.session.PutFile(f.clearPath, of.data); err != nil {
		return syscall.EIO
	}
	of.dirty = false
	f.mu.Lock()
	f.data = append([]byte(nil), of.data...)
	f.loaded = true
	f.mu.Unlock()
	return 0
}

func (f *fileNode) Setattr(ctx context.Context, fh fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	if !f.rw {
		return syscall.EROFS
	}
	if sz, ok := in.GetSize(); ok {
		of, isOpen := fh.(*openFile)
		if isOpen {
			of.mu.Lock()
			if int(sz) < len(of.data) {
				of.data = of.data[:sz]
			} else if int(sz) > len(of.data) {
				grown := make([]byte, sz)
				copy(grown, of.data)
				of.data = grown
			}
			of.dirty = true
			of.mu.Unlock()
			if errno := f.commit(of); errno != 0 {
				return errno
			}
		} else {
			if errno := f.load(); errno != 0 {
				return errno
			}
			f.mu.Lock()
			if int(sz) < len(f.data) {
				f.data = f.data[:sz]
			} else if int(sz) > len(f.data) {
				grown := make([]byte, sz)
				copy(grown, f.data)
				f.data = grown
			}
			data := append([]byte(nil), f.data...)
			f.mu.Unlock()
			if err := f.session.PutFile(f.clearPath, data); err != nil {
				return syscall.EIO
			}
		}
	}
	return f.Getattr(ctx, fh, out)
}

// openFile is the per-open buffer; Flush/Fsync push ciphertext via PutFile.
type openFile struct {
	node  *fileNode
	mu    sync.Mutex
	data  []byte
	dirty bool
}

func join(parent, name string) string {
	if parent == "/" {
		return "/" + name
	}
	return strings.TrimSuffix(parent, "/") + "/" + name
}
