import Foundation
import Testing
@testable import Runnir

@Suite struct LicenseCatalogTests {
    private static let json = """
    {
      "generatedBy": "scripts/update-notices.sh",
      "groups": [
        {"name": "Runnir.app", "components": [
          {"name": "swift-nio", "version": "2.104.0", "license": "Apache-2.0 AND MIT", "source": "https://github.com/apple/swift-nio/tree/2.104.0", "texts": ["a"]}
        ]},
        {"name": "Runnir Core", "components": [
          {"name": "Go", "version": "1.27.3", "license": "BSD-3-Clause", "source": "https://go.dev/dl/", "texts": ["b"]},
          {"name": "google.golang.org/grpc", "version": "v1.85.0", "license": "Apache-2.0", "source": "https://proxy.golang.org/google.golang.org/grpc/@v/v1.85.0.zip", "texts": ["a", "n"]}
        ]},
        {"name": "act", "components": []}
      ],
      "texts": {"a": "Apache License", "b": "Copyright (c) 2009 The Go Authors.", "n": "Copyright 2014 gRPC authors."}
    }
    """

    private func catalog() throws -> LicenseCatalog {
        let url = FileManager.default.temporaryDirectory.appending(path: "notices-\(UUID().uuidString).json")
        try Data(Self.json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(LicenseCatalog.load(from: url))
    }

    @Test func readsTheGroupsComponentsAndTexts() throws {
        let catalog = try catalog()
        #expect(catalog.groups.map(\.name) == ["Runnir.app", "Runnir Core", "act"])
        #expect(catalog.count == 3)
        let grpc = try #require(catalog.groups[1].components.last)
        #expect(grpc.texts.compactMap { catalog.texts[$0] } == ["Apache License", "Copyright 2014 gRPC authors."])
    }

    @Test func searchesByNameAndLicenseAndDropsEmptyGroups() throws {
        let catalog = try catalog()
        #expect(catalog.groups(matching: "") == catalog.groups)
        #expect(catalog.groups(matching: "  GRPC ").map(\.name) == ["Runnir Core"])
        #expect(catalog.groups(matching: "grpc").first?.components.map(\.name) == ["google.golang.org/grpc"])
        let mit = catalog.groups(matching: "mit")
        #expect(mit.map(\.name) == ["Runnir.app"])
        #expect(catalog.groups(matching: "apache-2.0").flatMap(\.components).map(\.name) == ["swift-nio", "google.golang.org/grpc"])
        #expect(catalog.groups(matching: "gpl").isEmpty)
    }

    @Test func aMissingOrDamagedFileGivesNoCatalog() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).json")
        #expect(LicenseCatalog.load(from: missing) == nil)
        let damaged = FileManager.default.temporaryDirectory.appending(path: "damaged-\(UUID().uuidString).json")
        try Data("{\"groups\": 1}".utf8).write(to: damaged)
        defer { try? FileManager.default.removeItem(at: damaged) }
        #expect(LicenseCatalog.load(from: damaged) == nil)
    }

    @Test func theAppCarriesTheNoticesAndItsLicense() throws {
        // The unit tests run inside the built app, so its bundle is the one
        // the build script filled.
        let catalog = try #require(LicenseCatalog.bundled())
        #expect(catalog.groups.map(\.name) == ["Runnir.app", "Runnir Core", "act"])
        #expect(catalog.groups.allSatisfy { !$0.components.isEmpty })
        for component in catalog.groups.flatMap(\.components) {
            #expect(!component.texts.isEmpty && component.texts.allSatisfy { catalog.texts[$0] != nil }, "\(component.name)")
        }
        let license = try #require(LicenseCatalog.runnirLicense())
        #expect(license.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Apache License"))
    }
}
