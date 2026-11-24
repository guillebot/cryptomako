# fp-capability-probe

Throwaway File Provider (bundle `net.gschimmel.cryptomako.probe`, domain `probe`,
Finder location `~/Library/CloudStorage/CMProbe-CMProbe`) used to prove, without
touching the real CryptoMako domain, that:

1. `enumeratorForMaterializedItems()` (empty start page) lists downloaded items, and
2. a working-set `didUpdate` with a new `metadataVersion` replaces the capabilities
   of an already-materialized item (Remove Download appears).

Items: `dir/a.txt`, `dir/b.txt`. Phase 1 = no `.allowsEvicting`; phase 2 adds it.

```sh
xcodegen generate
xcodebuild archive -project CMProbe.xcodeproj -scheme CMProbe -configuration Release \
  -archivePath .dd/CMProbe.xcarchive -derivedDataPath .dd -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates ENABLE_HARDENED_RUNTIME=YES
xcodebuild -exportArchive -archivePath .dd/CMProbe.xcarchive -exportPath .dd/export \
  -exportOptionsPlist .dd/export.plist -allowProvisioningUpdates   # method developer-id
P=.dd/export/CMProbe.app/Contents/MacOS/CMProbe
$P mode materialized; $P phase 1; $P add
# macOS registers new File Provider domains user-disabled: enable "CMProbe" once in
# System Settings > General > Login Items & Extensions > File Providers.
cat ~/Library/CloudStorage/CMProbe-CMProbe/dir/a.txt          # materialize a.txt
fileproviderctl evaluate ~/Library/CloudStorage/CMProbe-CMProbe/dir/a.txt   # no 'e'
$P phase 2                                                     # signal working set
log show --last 5m --predicate 'subsystem == "net.gschimmel.cryptomako.probe"'
fileproviderctl evaluate ~/Library/CloudStorage/CMProbe-CMProbe/dir/a.txt   # expect +64 / 'e'
$P remove
```
