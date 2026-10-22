# ExteraExport

Foundation models and HTML/JSON encoders for a cloud-chat text export. No account access, network, or file writes occur in the package.

```swift
var history = ExteraExportAccumulator()
try history.append(page) // Descending server IDs, including omitted records.
// Request earlier pages until a successful empty page is appended.
let document = try history.document(peerId: peerId, title: title)
let json = try ExteraExportEncoder.json(document)
let html = ExteraExportEncoder.html(document)
```

An unfinished traversal cannot create a document through the accumulator. Repeated pages, inconsistent end markers, record limits and content limits throw; they do not silently truncate the output. Defaults are 100,000 server records and a conservative 20 MiB content budget. Messages are sorted by server ID for output. All HTML text is escaped and no links or external assets are generated.

Run `swift test` in this directory. See [integration, APK evidence and limitations](../../docs/EXPORT.md) for the actual TelegramCore page API, menu action and verification status. The schema is specific to the iOS port and includes text plus attachment metadata, without binaries.
