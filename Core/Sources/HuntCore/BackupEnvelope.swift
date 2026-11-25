import Foundation

public struct BackupEnvelope: Codable, Sendable {
    public let schema: Int
    public let createdAt: Date
    public let files: [Entry]
    public struct Entry: Codable, Sendable {
        public let name: String
        public let bytes: Data
        public let sha256: String
        public init(name:String,bytes:Data,sha256:String) {self.name=name;self.bytes=bytes;self.sha256=sha256}
    }
    public init(createdAt:Date=Date(),files:[Entry]) {schema=1;self.createdAt=createdAt;self.files=files}
    public func validateStructure(required:Set<String>,maxBytes:Int=150_000_000) throws {
        guard schema==1,files.count==required.count,Set(files.map(\.name))==required else {throw CocoaError(.fileReadCorruptFile)}
        var total=0
        for f in files {
            guard f.bytes.count<=maxBytes-total,f.sha256.count==64,
                  f.sha256.allSatisfy({"0123456789abcdef".contains($0)}) else {throw CocoaError(.fileReadCorruptFile)}
            total += f.bytes.count
        }
    }
}
public enum BackupMerge {
    // Existing local records win on duplicate identity.
    public static func records<T,ID:Hashable>(_ local:[T],_ incoming:[T],id:(T)->ID)->[T] {
        var seen=Set<ID>()
        return (local+incoming).filter {seen.insert(id($0)).inserted}
    }
}
