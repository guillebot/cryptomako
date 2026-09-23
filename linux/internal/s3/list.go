package s3

import (
	"encoding/xml"
	"fmt"
	"strings"
)

// listBucketResult is the ListObjectsV2 XML shape (subset).
type listBucketResult struct {
	XMLName               xml.Name         `xml:"ListBucketResult"`
	IsTruncated           bool             `xml:"IsTruncated"`
	NextContinuationToken string           `xml:"NextContinuationToken"`
	Contents              []listContents   `xml:"Contents"`
	CommonPrefixes        []commonPrefix   `xml:"CommonPrefixes"`
}

type listContents struct {
	Key  string `xml:"Key"`
	Size int64  `xml:"Size"`
	ETag string `xml:"ETag"`
}

type commonPrefix struct {
	Prefix string `xml:"Prefix"`
}

// ParseListObjectsV2 parses a ListObjectsV2 XML response.
func ParseListObjectsV2(data []byte) (ListResult, error) {
	var raw listBucketResult
	if err := xml.Unmarshal(data, &raw); err != nil {
		return ListResult{}, fmt.Errorf("s3 list xml: %w", err)
	}
	out := ListResult{
		IsTruncated:           raw.IsTruncated,
		NextContinuationToken: raw.NextContinuationToken,
	}
	for _, c := range raw.Contents {
		etag := strings.Trim(c.ETag, "\"")
		out.Objects = append(out.Objects, Object{Key: c.Key, Size: c.Size, ETag: etag})
	}
	for _, p := range raw.CommonPrefixes {
		if p.Prefix != "" {
			out.CommonPrefixes = append(out.CommonPrefixes, p.Prefix)
		}
	}
	return out, nil
}
