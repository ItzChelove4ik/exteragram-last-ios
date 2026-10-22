import Foundation

/// Rendering-only reconstruction of the Lite APK's ZalgoFilter. Replacements
/// preserve UTF-16 length so message entities keep their original offsets.
public enum ExteraTextFilter {
    public static func filterZalgo(_ text: String) -> String {
        var units = Array(text.utf16)
        var offset = 0
        var markStart: Int?
        var markCount = 0
        var allowed = 4
        var ranges: [Range<Int>] = []

        func finishMarks(at end: Int) {
            if let start = markStart, markCount > allowed { ranges.append(start..<end) }
            markStart = nil
            markCount = 0
            allowed = 4
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let width = value > 0xFFFF ? 2 : 1
            let category = scalar.properties.generalCategory
            if value >= 0x0300 && (category == .nonspacingMark || category == .enclosingMark) {
                if markStart == nil { markStart = offset }
                markCount += 1
                let commonRange = (0x0300...0x036F).contains(value)
                    || (0x1AB0...0x1AFF).contains(value)
                    || (0x1DC0...0x1DFF).contains(value)
                    || (0x20D0...0x20FF).contains(value)
                    || (0xFE20...0xFE2F).contains(value)
                allowed = min(allowed, commonRange ? 2 : 4)
            } else {
                finishMarks(at: offset)
                if value == 0x061C || value == 0x200E || value == 0x200F
                    || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) {
                    ranges.append(offset..<(offset + width))
                }
            }
            offset += width
        }
        finishMarks(at: offset)
        guard !ranges.isEmpty else { return text }
        for range in ranges {
            for index in range { units[index] = 0x2060 }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
