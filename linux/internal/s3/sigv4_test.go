package s3

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// AWS published SigV4 vectors (bucket examplebucket, 2013-05-24).
var exampleCreds = Credentials{
	AccessKey: "AKIAIOSFODNN7EXAMPLE",
	SecretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
	Region:    "us-east-1",
}

func referenceTime() time.Time {
	return time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC)
}

func signatureFor(t *testing.T, rawURL string) string {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := SignRequest(req, exampleCreds, EmptyPayloadSHA256, referenceTime()); err != nil {
		t.Fatal(err)
	}
	auth := req.Header.Get("Authorization")
	idx := strings.Index(auth, "Signature=")
	if idx < 0 {
		t.Fatalf("no Signature in %q", auth)
	}
	return auth[idx+len("Signature="):]
}

func TestGetBucketLifecycleVector(t *testing.T) {
	got := signatureFor(t, "https://examplebucket.s3.amazonaws.com/?lifecycle=")
	want := "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
	if got != want {
		t.Fatalf("signature = %s want %s", got, want)
	}
}

func TestListObjectsVectorSortsQuery(t *testing.T) {
	got := signatureFor(t, "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")
	want := "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
	if got != want {
		t.Fatalf("signature = %s want %s", got, want)
	}
}

func TestAuthorizationHeaderShape(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "https://examplebucket.s3.amazonaws.com/?lifecycle=", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := SignRequest(req, exampleCreds, EmptyPayloadSHA256, referenceTime()); err != nil {
		t.Fatal(err)
	}
	if got := req.Header.Get("X-Amz-Date"); got != "20130524T000000Z" {
		t.Fatalf("x-amz-date = %q", got)
	}
	if got := req.Header.Get("X-Amz-Content-Sha256"); got != EmptyPayloadSHA256 {
		t.Fatalf("content-sha256 = %q", got)
	}
	if got := req.Header.Get("Host"); got != "examplebucket.s3.amazonaws.com" {
		t.Fatalf("host = %q", got)
	}
	auth := req.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request") {
		t.Fatalf("auth prefix: %q", auth)
	}
	if !strings.Contains(auth, "SignedHeaders=host;x-amz-content-sha256;x-amz-date") {
		t.Fatalf("signed headers: %q", auth)
	}
}

func TestHostHeaderKeepsNonDefaultPort(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "http://minio.example.net:9000/bucket/key", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := SignRequest(req, exampleCreds, EmptyPayloadSHA256, referenceTime()); err != nil {
		t.Fatal(err)
	}
	if got := req.Header.Get("Host"); got != "minio.example.net:9000" {
		t.Fatalf("host = %q", got)
	}
}

func TestCanonicalPathKeepsTrailingSlash(t *testing.T) {
	u, err := url.Parse("http://minio.example.net:9000/bucket/?list-type=2")
	if err != nil {
		t.Fatal(err)
	}
	if got := CanonicalPath(u); got != "/bucket/" {
		t.Fatalf("canonical path = %q", got)
	}
}

func TestCanonicalPathEncodesUnicodeSegments(t *testing.T) {
	u, err := url.Parse("http://minio.example.net:9000/bucket/caf%C3%A9%20r.txt")
	if err != nil {
		t.Fatal(err)
	}
	if got := CanonicalPath(u); got != "/bucket/caf%C3%A9%20r.txt" {
		t.Fatalf("canonical path = %q", got)
	}
}

func TestURIEncodePreservesSlashInPathOnly(t *testing.T) {
	if got := URIEncode("a/b c", false); got != "a/b%20c" {
		t.Fatalf("path encode = %q", got)
	}
	if got := URIEncode("a/b c", true); got != "a%2Fb%20c" {
		t.Fatalf("query encode = %q", got)
	}
	if got := URIEncode("café", false); got != "caf%C3%A9" {
		t.Fatalf("unicode = %q", got)
	}
	if got := URIEncode("-._~", false); got != "-._~" {
		t.Fatalf("unreserved = %q", got)
	}
}
