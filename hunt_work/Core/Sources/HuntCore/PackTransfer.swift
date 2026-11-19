import Foundation

/// Platform-independent validation of partial HTTP responses for an immutable SHA-256-addressed pack.
public enum PackTransfer {
    public enum ValidationError: Error, Equatable {
        case malformedRange, wrongOffset, wrongTotal, wrongLength, invalidChunk
    }

    /// Expected value of Content-Range: bytes START-END/TOTAL.
    public static func validate(contentRange: String?, offset: Int64, bytes: Int,
                                total: Int64, requested: Int) throws {
        guard let contentRange else { throw ValidationError.malformedRange }
        let expression = try NSRegularExpression(pattern: #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#)
        let range = NSRange(contentRange.startIndex..<contentRange.endIndex, in: contentRange)
        guard let match = expression.firstMatch(in: contentRange, range: range), match.range == range else {
            throw ValidationError.malformedRange
        }
        func number(_ index: Int) -> Int64? {
            guard let span = Range(match.range(at: index), in: contentRange) else { return nil }
            return Int64(contentRange[span])
        }
        guard let start = number(1), let end = number(2), let claimedTotal = number(3) else {
            throw ValidationError.malformedRange
        }
        guard start == offset else { throw ValidationError.wrongOffset }
        guard claimedTotal == total else { throw ValidationError.wrongTotal }
        guard end >= start, end < total, end - start + 1 == Int64(bytes) else {
            throw ValidationError.wrongLength
        }
        guard bytes > 0, bytes <= requested else { throw ValidationError.invalidChunk }
    }
}
