using System.Linq;
using System.Threading.Channels;

namespace CryptoMako.Vault;

/// <summary>
/// Walk cleartext tree → encrypt → parallel put with size-tiered concurrency.
/// Fail-closed: only counts durable after store put succeeds (HTTP 2xx on S3).
/// <para>
/// Transfer mode (<see cref="AppPreferences.BackupTransferMode"/>):
/// <list type="bullet">
/// <item><c>backup</c> (default): put/update only. Never deletes the local source. Never deletes vault extras.</item>
/// <item><c>sync</c>: same puts, then delete remote ciphertext under <c>Backups/&lt;folder&gt;/</c>
/// that is missing from the local tree (fail-closed). Never deletes the local source.</item>
/// </list>
/// </para>
/// </summary>
public sealed class BackupSyncEngine
{
    public const long LargeFileBytes = 32L * 1024 * 1024;
    public const long MediumFileBytes = 256L * 1024;

    public sealed class Result
    {
        public int FilesUploaded { get; init; }
        public int FilesSkipped { get; init; }
        public int FilesScanned { get; init; }
        public long BytesUploaded { get; init; }
        public long BytesScanned { get; init; }
        /// <summary>Vault ciphertext items removed in Sync mode. Always 0 in Backup mode.</summary>
        public int FilesDeleted { get; init; }
    }

    private readonly record struct PendingUpload(
        string AbsolutePath,
        string RelativePath,
        string ParentRelativeDir,
        string FileName,
        long Size,
        DateTimeOffset MtimeUtc);

    public async Task<Result> SyncAsync(
        VaultSession session,
        string localRoot,
        string vaultFolderName,
        AppPreferences preferences,
        BackupSyncExcludes? excludes = null,
        BackupSyncState? syncState = null,
        string? syncStatePath = null,
        IProgress<string>? progress = null,
        IProgress<BackupSyncProgressUpdate>? syncProgress = null,
        CancellationToken ct = default)
    {
        excludes ??= new BackupSyncExcludes();
        preferences.ClampSyncWorkers();
        preferences.BackupTransferMode = AppPreferences.NormalizeBackupTransferMode(preferences.BackupTransferMode);
        var isSyncMode = preferences.IsSyncTransferMode;
        syncState ??= string.IsNullOrEmpty(syncStatePath)
            ? new BackupSyncState()
            : BackupSyncState.LoadFromFile(syncStatePath);

        localRoot = Path.GetFullPath(localRoot);
        if (!Directory.Exists(localRoot))
            throw new DirectoryNotFoundException(localRoot);

        vaultFolderName = vaultFolderName.Trim().Trim('/');
        if (string.IsNullOrEmpty(vaultFolderName))
            throw new ArgumentException("vaultFolderName is required (scoped Backups/<folder>/ destination).", nameof(vaultFolderName));

        var vaultRoot = "Backups/" + vaultFolderName;
        progress?.Report("ensure " + vaultRoot);
        syncProgress?.Report(new BackupSyncProgressUpdate { Phase = "preparing", CurrentPath = vaultRoot });
        // ConfigureAwait(false): CollectJobs must not run on the WinUI dispatcher
        // (sync EnumerateFiles would freeze the UI on 'Counting local files...').
        var leafDirId = await session.EnsureDirectoryPathAsync(vaultRoot, ct).ConfigureAwait(false);

        var limiter = UploadBandwidthLimiter.FromPreferences(preferences);
        var opts = new UnboundedChannelOptions { SingleReader = false, SingleWriter = true };
        var smallCh = Channel.CreateUnbounded<PendingUpload>(opts);
        var mediumCh = Channel.CreateUnbounded<PendingUpload>(opts);
        var largeCh = Channel.CreateUnbounded<PendingUpload>(opts);

        var uploaded = 0;
        long bytes = 0;
        var stateLock = new object();
        var dirCache = new Dictionary<string, string>(StringComparer.Ordinal) { [""] = leafDirId };
        var dirCacheLock = new object();
        var rateWindowStart = DateTime.UtcNow;
        long rateWindowBytes = 0;
        double emaRate = 0;
        var filesTotal = 0;
        long bytesTotal = 0;
        // Filled after CollectJobs; WorkerAsync captures these for honest scanned totals.
        var skippedBaseline = 0;
        long skippedBytesBaseline = 0;
        var filesScannedTotal = 0;
        long bytesScannedTotal = 0;

        // Serialize EnsureDirectoryPathAsync — parallel workers otherwise race-create
        // duplicate Cryptomator dirs for the same cleartext name (and can stall).
        var dirEnsureGate = new SemaphoreSlim(1, 1);

        async Task<string> ResolveParentDirIdAsync(string parentRelativeDir)
        {
            lock (dirCacheLock)
            {
                if (dirCache.TryGetValue(parentRelativeDir, out var hit))
                    return hit;
            }

            await dirEnsureGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                lock (dirCacheLock)
                {
                    if (dirCache.TryGetValue(parentRelativeDir, out var hit))
                        return hit;
                }

                var full = string.IsNullOrEmpty(parentRelativeDir)
                    ? vaultRoot
                    : vaultRoot + "/" + parentRelativeDir.Replace('\\', '/');
                var id = await session.EnsureDirectoryPathAsync(full, ct).ConfigureAwait(false);
                lock (dirCacheLock)
                    dirCache[parentRelativeDir] = id;
                return id;
            }
            finally
            {
                dirEnsureGate.Release();
            }
        }

        async Task WorkerAsync(ChannelReader<PendingUpload> reader)
        {
            await foreach (var job in reader.ReadAllAsync(ct))
            {
                ct.ThrowIfCancellationRequested();
                if (limiter is not null)
                    await limiter.AcquireAsync(job.Size, ct);

                // Surface the in-flight file BEFORE put so UI never looks stuck on N-1/N
                // while the last PutFileAsync is still running (or hung).
                syncProgress?.Report(new BackupSyncProgressUpdate
                {
                    Phase = "uploading",
                    FilesDone = skippedBaseline + uploaded,
                    FilesTotal = filesScannedTotal,
                    FilesSkipped = skippedBaseline,
                    FilesScanned = filesScannedTotal,
                    BytesDone = skippedBytesBaseline + bytes,
                    BytesTotal = bytesScannedTotal,
                    BytesScanned = bytesScannedTotal,
                    BytesPerSecond = emaRate,
                    CurrentPath = job.RelativePath,
                });
                progress?.Report(job.RelativePath);

                var parentId = await ResolveParentDirIdAsync(job.ParentRelativeDir);

                // Per-file timeout: fail closed with a clear error instead of hanging forever.
                const int putTimeoutSeconds = 120;
                using var putCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                putCts.CancelAfter(TimeSpan.FromSeconds(putTimeoutSeconds));
                try
                {
                    await session.PutFileAsync(parentId, job.FileName, job.AbsolutePath, putCts.Token)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new TimeoutException(
                        $"Backup Sync timed out after {putTimeoutSeconds}s on: {job.RelativePath}");
                }

                var key = BackupSyncState.Key(vaultFolderName, job.RelativePath);
                BackupSyncProgressUpdate? update = null;
                lock (stateLock)
                {
                    syncState.Files[key] = new BackupFileFingerprint
                    {
                        Size = job.Size,
                        ContentModificationUtcTicks = job.MtimeUtc.UtcTicks,
                    };
                    uploaded++;
                    bytes += job.Size;
                    rateWindowBytes += job.Size;
                    var elapsed = (DateTime.UtcNow - rateWindowStart).TotalSeconds;
                    if (elapsed >= 0.5)
                    {
                        var instant = rateWindowBytes / Math.Max(elapsed, 0.001);
                        emaRate = emaRate <= 0 ? instant : (emaRate * 0.7 + instant * 0.3);
                        rateWindowStart = DateTime.UtcNow;
                        rateWindowBytes = 0;
                    }
                    update = new BackupSyncProgressUpdate
                    {
                        Phase = "uploading",
                        FilesDone = skippedBaseline + uploaded,
                        FilesTotal = filesScannedTotal,
                        FilesSkipped = skippedBaseline,
                        FilesScanned = filesScannedTotal,
                        BytesDone = skippedBytesBaseline + bytes,
                        BytesTotal = bytesScannedTotal,
                        BytesScanned = bytesScannedTotal,
                        BytesPerSecond = emaRate,
                        CurrentPath = job.RelativePath,
                    };
                }
                if (update is not null)
                    syncProgress?.Report(update);
            }
        }

        syncProgress?.Report(new BackupSyncProgressUpdate
        {
            Phase = "scanning",
            CurrentPath = localRoot,
        });
        // Offload the sync walk so Progress<T> callbacks can marshal to the UI thread.
        var (jobs, skipped, skippedBytes, localFiles) = await Task.Run(
            () => CollectJobs(localRoot, excludes, syncState, vaultFolderName, syncProgress, ct),
            ct).ConfigureAwait(false);
        filesTotal = jobs.Count;
        bytesTotal = jobs.Sum(j => j.Size);
        var filesScanned = jobs.Count + skipped;
        var bytesScanned = bytesTotal + skippedBytes;
        // Baselines for worker closures: progress denominator = all scanned regular files.
        skippedBaseline = skipped;
        skippedBytesBaseline = skippedBytes;
        filesScannedTotal = filesScanned;
        bytesScannedTotal = bytesScanned;
        if (filesScanned == 0)
            throw new InvalidOperationException(
                "No regular files found under backup source: " + localRoot);
        string startMsg;
        if (filesTotal == 0)
            startMsg = $"All {skipped} files up-to-date";
        else if (skipped > 0)
            startMsg = $"Starting upload... ({skipped} already up-to-date)";
        else
            startMsg = "Starting upload...";
        syncProgress?.Report(new BackupSyncProgressUpdate
        {
            Phase = filesTotal == 0 ? "done" : "uploading",
            FilesDone = skipped,
            FilesTotal = filesScanned,
            FilesSkipped = skipped,
            FilesScanned = filesScanned,
            BytesDone = filesTotal == 0 ? bytesScanned : skippedBytes,
            BytesTotal = bytesScanned,
            BytesScanned = bytesScanned,
            CurrentPath = startMsg,
        });

        var workers = new List<Task>();
        for (var i = 0; i < preferences.ClampedSmallPutConcurrency; i++)
            workers.Add(Task.Run(() => WorkerAsync(smallCh.Reader), ct));
        for (var i = 0; i < preferences.ClampedMediumPutConcurrency; i++)
            workers.Add(Task.Run(() => WorkerAsync(mediumCh.Reader), ct));
        for (var i = 0; i < preferences.ClampedLargePutConcurrency; i++)
            workers.Add(Task.Run(() => WorkerAsync(largeCh.Reader), ct));

        try
        {
            foreach (var job in jobs)
            {
                ct.ThrowIfCancellationRequested();
                if (job.Size >= LargeFileBytes)
                    await largeCh.Writer.WriteAsync(job, ct);
                else if (job.Size >= MediumFileBytes)
                    await mediumCh.Writer.WriteAsync(job, ct);
                else
                    await smallCh.Writer.WriteAsync(job, ct);
            }
        }
        finally
        {
            smallCh.Writer.Complete();
            mediumCh.Writer.Complete();
            largeCh.Writer.Complete();
        }

        await Task.WhenAll(workers);

        var filesDeleted = 0;
        if (isSyncMode)
        {
            syncProgress?.Report(new BackupSyncProgressUpdate
            {
                Phase = "pruning",
                FilesDone = skipped + uploaded,
                FilesTotal = filesScanned,
                FilesSkipped = skipped,
                FilesScanned = filesScanned,
                BytesDone = skippedBytes + bytes,
                BytesTotal = bytesScanned,
                BytesScanned = bytesScanned,
                CurrentPath = $"Comparing vault {vaultRoot}/ to local tree…",
            });
            filesDeleted = await DeleteVaultOrphansAsync(
                session,
                leafDirId,
                localFiles,
                vaultFolderName,
                syncState,
                syncProgress,
                ct).ConfigureAwait(false);
            syncProgress?.Report(new BackupSyncProgressUpdate
            {
                Phase = "pruning",
                FilesDone = skipped + uploaded,
                FilesTotal = filesScanned,
                FilesSkipped = skipped,
                FilesScanned = filesScanned,
                BytesDone = skippedBytes + bytes,
                BytesTotal = bytesScanned,
                BytesScanned = bytesScanned,
                FilesDeleted = filesDeleted,
                CurrentPath = filesDeleted == 0
                    ? "No vault-only files to remove"
                    : $"Removed {filesDeleted} vault-only item(s)",
            });
        }

        if (!string.IsNullOrEmpty(syncStatePath))
            syncState.SaveToFile(syncStatePath);

        return new Result
        {
            FilesUploaded = uploaded,
            FilesSkipped = skipped,
            FilesScanned = filesScanned,
            BytesUploaded = bytes,
            BytesScanned = bytesScanned,
            FilesDeleted = filesDeleted,
        };
    }

    /// <summary>
    /// Sync mode only: delete remote ciphertext under this source's vault folder that
    /// has no matching eligible local file. Never touches the local source tree.
    /// Fail-closed: ObjectStore/<see cref="VaultSession"/> delete errors abort the run.
    /// Scope is <c>Backups/&lt;folder&gt;/</c> only (leafDirId); never vault root.
    /// </summary>
    private static async Task<int> DeleteVaultOrphansAsync(
        VaultSession session,
        string rootDirId,
        HashSet<string> localFiles,
        string vaultFolderName,
        BackupSyncState syncState,
        IProgress<BackupSyncProgressUpdate>? syncProgress,
        CancellationToken ct)
    {
        static bool HasLocalUnder(HashSet<string> locals, string relDir)
        {
            // Source vault root always stays; only prune children.
            if (string.IsNullOrEmpty(relDir)) return true;
            if (locals.Contains(relDir)) return true;
            var prefix = relDir + "/";
            foreach (var path in locals)
            {
                if (path.StartsWith(prefix, StringComparison.Ordinal))
                    return true;
            }
            return false;
        }

        async Task<int> PruneAsync(string dirId, string relPrefix)
        {
            ct.ThrowIfCancellationRequested();
            var children = await session.ListNodesByDirIdAsync(dirId, ct).ConfigureAwait(false);
            var deleted = 0;
            foreach (var child in children)
            {
                ct.ThrowIfCancellationRequested();
                var childRel = string.IsNullOrEmpty(relPrefix)
                    ? child.CleartextName
                    : relPrefix + "/" + child.CleartextName;
                syncProgress?.Report(new BackupSyncProgressUpdate
                {
                    Phase = "pruning",
                    CurrentPath = childRel,
                    FilesDeleted = deleted,
                });

                switch (child.Kind)
                {
                    case NodeKind.File:
                    case NodeKind.Symlink:
                        if (!localFiles.Contains(childRel))
                        {
                            // Remote ObjectStore ciphertext delete only — never local source.
                            await session.DeleteFileAsync(child, ct).ConfigureAwait(false);
                            syncState.RemoveUnder(vaultFolderName, childRel, isDirectory: false);
                            deleted++;
                        }
                        break;
                    case NodeKind.Directory:
                        if (string.IsNullOrEmpty(child.DirId))
                            continue;
                        if (!HasLocalUnder(localFiles, childRel))
                        {
                            // Entire subtree is vault-only under this source folder.
                            await session.DeleteDirectoryAsync(child, recursive: true, ct)
                                .ConfigureAwait(false);
                            syncState.RemoveUnder(vaultFolderName, childRel, isDirectory: true);
                            deleted++;
                        }
                        else
                        {
                            deleted += await PruneAsync(child.DirId, childRel).ConfigureAwait(false);
                        }
                        break;
                }
            }
            return deleted;
        }

        return await PruneAsync(rootDirId, "").ConfigureAwait(false);
    }

    private static (List<PendingUpload> Jobs, int Skipped, long SkippedBytes, HashSet<string> LocalFiles) CollectJobs(
        string localRoot,
        BackupSyncExcludes excludes,
        BackupSyncState syncState,
        string vaultFolderName,
        IProgress<BackupSyncProgressUpdate>? syncProgress = null,
        CancellationToken ct = default)
    {
        var jobs = new List<PendingUpload>();
        var localFiles = new HashSet<string>(StringComparer.Ordinal);
        var skipped = 0;
        long skippedBytes = 0;
        var scanned = 0;
        long scannedBytes = 0;
        var sinceUi = 0;
        var lastUi = System.Diagnostics.Stopwatch.StartNew();
        var rootFull = localRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        // Default SearchOption.AllDirectories follows dir junctions and aborts the whole
        // walk on the first UnauthorizedAccessException (e.g. C:\Users\...\Application Data
        // under a home-folder Backup source) - UI stuck at "Counting... 1 files".
        // Keep default Hidden|System skip AND skip ReparsePoint so junctions are not entered.
        var enumOpts = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint,
            ReturnSpecialDirectories = false,
        };
        foreach (var path in Directory.EnumerateFiles(localRoot, "*", enumOpts))
        {
            ct.ThrowIfCancellationRequested();
            var rel = Path.GetRelativePath(rootFull, path).Replace('\\', '/');
            var parts = rel.Split('/');
            var hide = false;
            for (var i = 0; i < parts.Length; i++)
            {
                if (parts[i].StartsWith('.')) { hide = true; break; }
                if (i < parts.Length - 1 && excludes.ShouldSkipDirectory(parts[i])) { hide = true; break; }
            }
            if (hide) continue;
            if (excludes.ShouldSkipRelativePath(rel)) continue;

            FileInfo info;
            long length;
            DateTimeOffset mtime;
            try
            {
                info = new FileInfo(path);
                if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    continue;
                length = info.Length;
                mtime = info.LastWriteTimeUtc;
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
                continue;
            }

            // Eligible local file (post-exclude). Used by Sync-mode orphan prune.
            localFiles.Add(rel);

            scanned++;
            scannedBytes += length;
            sinceUi++;
            // First file immediately; then ~10Hz or every 25 files (macOS live-name parity).
            // Do not set FilesDone/BytesDone here - Percent would jump to 100% while counting.
            if (scanned == 1 || sinceUi >= 25 || lastUi.ElapsedMilliseconds >= 100)
            {
                sinceUi = 0;
                lastUi.Restart();
                syncProgress?.Report(new BackupSyncProgressUpdate
                {
                    Phase = "scanning",
                    FilesScanned = scanned,
                    BytesScanned = scannedBytes,
                    CurrentPath = rel,
                });
            }

            var key = BackupSyncState.Key(vaultFolderName, rel);
            if (syncState.Files.TryGetValue(key, out var fp) && fp.Matches(length, mtime))
            {
                skipped++;
                skippedBytes += length;
                continue;
            }

            var parentRel = Path.GetDirectoryName(rel)?.Replace('\\', '/') ?? "";
            if (parentRel == ".") parentRel = "";
            jobs.Add(new PendingUpload(path, rel, parentRel, Path.GetFileName(path), length, mtime));
        }

        syncProgress?.Report(new BackupSyncProgressUpdate
        {
            Phase = "scanning",
            FilesScanned = scanned,
            BytesScanned = scannedBytes,
            CurrentPath = scanned == 0
                ? localRoot
                : $"Scan complete - {scanned} files",
        });
        return (jobs, skipped, skippedBytes, localFiles);
    }
}
