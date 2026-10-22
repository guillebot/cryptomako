namespace CryptoMako.Vault;

/// <summary>
/// Pure upload-progress math for the Backup UI.
/// Mirrors <c>Sources/CryptoMakoShared/BackupUploadProgress.swift</c>.
/// After the scan finishes, progress is uploaded / to-upload (cleartext bytes).
/// Skipped files are not progress. During the scan there is no determinate percent.
/// </summary>
public static class BackupUploadProgress
{
    /// <summary>
    /// Null while scanning. After scan: 0…1 from bytesUploaded / bytesToUpload.
    /// Empty to-upload set → 1.
    /// </summary>
    public static double? Fraction(bool walkFinished, long bytesUploaded, long bytesToUpload)
    {
        if (!walkFinished) return null;
        if (bytesToUpload <= 0) return 1;
        return Math.Min(1, Math.Max(0, (double)bytesUploaded / bytesToUpload));
    }

    public static string PercentLabel(
        bool walkFinished,
        long bytesUploaded,
        long bytesToUpload,
        bool jobFinished = false)
    {
        if (jobFinished) return "100%";
        var frac = Fraction(walkFinished, bytesUploaded, bytesToUpload);
        if (frac is null) return "Scanning";
        var pct = (int)Math.Floor(frac.Value * 100);
        return $"{pct}%";
    }
}
