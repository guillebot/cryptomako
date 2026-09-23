package s3

import "testing"

func TestParseListObjectsV2(t *testing.T) {
	xml := `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <Name>sch-backup</Name>
  <Prefix>cryptomako-poc/</Prefix>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>cryptomako-poc/vault.cryptomator</Key>
    <Size>283</Size>
    <ETag>"abc123"</ETag>
  </Contents>
  <CommonPrefixes><Prefix>cryptomako-poc/d/</Prefix></CommonPrefixes>
</ListBucketResult>`
	result, err := ParseListObjectsV2([]byte(xml))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Objects) != 1 || result.Objects[0].Key != "cryptomako-poc/vault.cryptomator" {
		t.Fatalf("objects = %+v", result.Objects)
	}
	if result.Objects[0].Size != 283 || result.Objects[0].ETag != "abc123" {
		t.Fatalf("object meta = %+v", result.Objects[0])
	}
	if len(result.CommonPrefixes) != 1 || result.CommonPrefixes[0] != "cryptomako-poc/d/" {
		t.Fatalf("prefixes = %+v", result.CommonPrefixes)
	}
	if result.IsTruncated {
		t.Fatal("truncated")
	}
}

func TestParseListObjectsV2RejectsMalformed(t *testing.T) {
	_, err := ParseListObjectsV2([]byte("<not-closed"))
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestParseListObjectsV2MultipleContents(t *testing.T) {
	xml := `<ListBucketResult>
  <Contents><Key>a</Key><Size>1</Size></Contents>
  <Contents><Key>b</Key><Size>2</Size><ETag>"x"</ETag></Contents>
  <CommonPrefixes><Prefix>p/</Prefix></CommonPrefixes>
</ListBucketResult>`
	result, err := ParseListObjectsV2([]byte(xml))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Objects) != 2 || result.Objects[0].Key != "a" || result.Objects[1].Key != "b" {
		t.Fatalf("objects = %+v", result.Objects)
	}
}
