package config

// BackupSyncScanDisposition mirrors Sources/CryptoMakoShared/BackupSyncPresentSetPolicy.swift.
// Prune allow-set is "present on disk"; upload eligibility is separate.
type BackupSyncScanDisposition int

const (
	// PresentUploadEligible: on disk for prune; may fingerprint / upload.
	PresentUploadEligible BackupSyncScanDisposition = iota
	// PresentDoNotUpload: on disk for prune; must not upload (excluded or hidden).
	PresentDoNotUpload
)

// Disposition returns prune/upload policy for a path that exists under the source root.
func Disposition(isHidden, isExcluded bool) BackupSyncScanDisposition {
	if isHidden || isExcluded {
		return PresentDoNotUpload
	}
	return PresentUploadEligible
}

// RetainInPruneAllowSet is true in Sync mode for every path present on disk
// (including excluded/hidden). Backup mode does not retain a present-set.
func RetainInPruneAllowSet(isSyncMode, pathPresentOnDisk bool) bool {
	return isSyncMode && pathPresentOnDisk
}
