using System.Linq;
using System.Threading.Channels;

namespace CryptoMako.Vault;

/// <summary>
/// Walk cleartext tree → encrypt → parallel put with size-tiered concurrency.
/// Fail-closed: only counts durable after store put succeeds (HTTP 2xx on S3).
/// </summary>
public sealed class BackupSyncEngine
{
    public const long LargeFileBytes = 32L * 1024 * 1024;
    public const long MediumFileBytes = 256L * 1024;

    public sealed class Result
    {
        public int FilesUploaded { get; init; }
        public int FilesSkipped { get; init; }
        public long BytesUploaded { get; init; }
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
        syncState ??= string.IsNullOrEmpty(syncStatePath)
            ? new BackupSyncState()
            : BackupSyncState.LoadFromFile(syncStatePath);

        localRoot = Path.GetFullPath(localRoot);
        if (!Directory.Exists(localRoot))
            throw new DirectoryNotFoundException(localRoot);

        var vaultRoot = "Backups/" + vaultFolderName.Trim().Trim('/');
        progress?.Report("ensure " + vaultRoot);
        syncProgress?.Report(new BackupSyncProgressUpdate { Phase = "preparing", CurrentPath = vaultRoot });
        var leafDirId = await session.EnsureDirectoryPathAsync(vaultRoot, ct);

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
                    FilesDone = uploaded,
                    FilesTotal = filesTotal,
                    BytesDone = bytes,
                    BytesTotal = bytesTotal,
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
                        FilesDone = uploaded,
                        FilesTotal = filesTotal,
                        BytesDone = bytes,
                        BytesTotal = bytesTotal,
                        BytesPerSecond = emaRate,
                        CurrentPath = job.RelativePath,
                    };
                }
                if (update is not null)
                    syncProgress?.Report(update);
            }
        }

        syncProgress?.Report(new BackupSyncProgressUpdate { Phase = "scanning", CurrentPath = localRoot });
        var (jobs, skipped) = CollectJobs(localRoot, excludes, syncState, vaultFolderName);
        filesTotal = jobs.Count;
        bytesTotal = jobs.Sum(j => j.Size);
        syncProgress?.Report(new BackupSyncProgressUpdate
        {
            Phase = "uploading",
            FilesDone = 0,
            FilesTotal = filesTotal,
            BytesDone = 0,
            BytesTotal = bytesTotal,
            CurrentPath = filesTotal == 0 ? "No regular files to upload" : "Starting upload…",
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

        if (!string.IsNullOrEmpty(syncStatePath))
            syncState.SaveToFile(syncStatePath);

        return new Result
        {
            FilesUploaded = uploaded,
            FilesSkipped = skipped,
            BytesUploaded = bytes,
        };
    }

    private static (List<PendingUpload> Jobs, int Skipped) CollectJobs(
        string localRoot,
        BackupSyncExcludes excludes,
        BackupSyncState syncState,
        string vaultFolderName)
    {
        var jobs = new List<PendingUpload>();
        var skipped = 0;
        var rootFull = localRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        foreach (var path in Directory.EnumerateFiles(localRoot, "*", SearchOption.AllDirectories))
        {
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

            var info = new FileInfo(path);
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
                continue;

            var mtime = info.LastWriteTimeUtc;
            var key = BackupSyncState.Key(vaultFolderName, rel);
            if (syncState.Files.TryGetValue(key, out var fp) && fp.Matches(info.Length, mtime))
            {
                skipped++;
                continue;
            }

            var parentRel = Path.GetDirectoryName(rel)?.Replace('\\', '/') ?? "";
            if (parentRel == ".") parentRel = "";
            jobs.Add(new PendingUpload(path, rel, parentRel, Path.GetFileName(path), info.Length, mtime));
        }
        return (jobs, skipped);
    }
}
