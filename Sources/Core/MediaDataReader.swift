import Foundation

/// An SDK response may already contain Data. This adapter exposes the same bounded read API.
actor MediaDataReader {
    private var data: Data?
    private var offset = 0
    init(_ data: Data) { self.data = data }
    func read() -> Data? {
        guard let data, offset < data.count else { self.data = nil; return nil }
        let end = offset + min(65_536, data.count - offset)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}
