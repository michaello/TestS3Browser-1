import Foundation

enum MetadataCatalogQuery {
    static func newestReports(_ records: [MetadataRecord], limit: Int) throws -> [MetadataRecord] {
        let count = try RecentShortcutCount(limit)
        return Array(records.sorted { $1.key.utf8.lexicographicallyPrecedes($0.key.utf8) }.prefix(count.value))
    }

    /// Select from the complete source before limiting output. Query views never
    /// mutate the catalog that Recent, Stats, shortcuts and widgets share.
    static func select(_ snapshot: MetadataCatalogSnapshot, limit: Int,
                       search: String? = nil, bucket: String? = nil,
                       matching: (MetadataRecord) -> Bool = { _ in true }) throws -> [MetadataRecord] {
        let count = try RecentShortcutCount(limit)
        let term = search?.lowercased()
        return Array(snapshot.records.filter { record in
            (bucket.map { record.bucket.utf8.elementsEqual($0.utf8) } ?? true) &&
            (term.map { record.key.lowercased().contains($0) } ?? true) && matching(record)
        }.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            let bucketA = Data($0.bucket.utf8), bucketB = Data($1.bucket.utf8)
            if bucketA != bucketB { return bucketA.lexicographicallyPrecedes(bucketB) }
            return $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }.prefix(count.value))
    }
}
