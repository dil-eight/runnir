import Foundation

struct Artifact: Identifiable, Equatable, Sendable {
    let id: Int64
    let runID: Int64
    let name: String
    let sizeInBytes: Int
    let expiresAt: Date
    let digest: String?
}
