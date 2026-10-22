# ExteraSpeech

File-based, on-device speech recognition for the exteraGram iOS port. The production backend uses Apple's Speech framework on iOS 15+, checks real on-device capability and forbids network recognition fallback. Other platforms have an explicit unsupported backend so coordinator tests can run without permission prompts.

```swift
let transcriber = ExteraSpeechTranscriber()
let task = transcriber.transcribe(fileURL: downloadedAudio, localeIdentifier: "ru-RU") { result in
    // Main-thread, serial delivery by default; exactly one terminal result.
}
// task.cancel()
```

The host application must provide a nonempty `NSSpeechRecognitionUsageDescription`. Audio must be a local, readable, nonempty regular file supported by AVAudioFile. The UI adapter converts downloaded Telegram voice/Opus media to AAC before invoking the package.

Run `swift test` in this directory on a Swift-capable host. Tests inject a backend; they do not exercise Apple's model availability or accuracy. See [the integration and adaptation notes](../../docs/SPEECH.md) for behavior, provenance and verification limits.
