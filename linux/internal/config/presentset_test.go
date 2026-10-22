package config

import "testing"

func TestDispositionExcludedNotUploadEligible(t *testing.T) {
	if Disposition(false, true) != PresentDoNotUpload {
		t.Fatal("excluded must be presentDoNotUpload")
	}
	if !RetainInPruneAllowSet(true, true) {
		t.Fatal("sync retains present paths")
	}
}

func TestDispositionHiddenNotUploadEligible(t *testing.T) {
	if Disposition(true, false) != PresentDoNotUpload {
		t.Fatal("hidden must be presentDoNotUpload")
	}
}

func TestDispositionEligible(t *testing.T) {
	if Disposition(false, false) != PresentUploadEligible {
		t.Fatal("want presentUploadEligible")
	}
}

func TestRetainAbsentAndBackupMode(t *testing.T) {
	if RetainInPruneAllowSet(true, false) {
		t.Fatal("absent path must not be retained")
	}
	if RetainInPruneAllowSet(false, true) {
		t.Fatal("backup mode must not retain present-set")
	}
}
