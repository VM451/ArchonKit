import Foundation
import Testing
@testable import ArchonModels
import ArchonCore

private struct ZooStubHTTPClient: ModelHTTPClient {
    let payload: Data
    let statusCode: Int

    init(payload: Data, statusCode: Int = 200) {
        self.payload = payload
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
            throw ArchonModelsError.invalidResponse
        }
        return (payload, response)
    }
}

private let zooFixtureJSON = """
{
    "generated": "2026-09-28",
    "models": [
        {
            "family": "s1-mini",
            "card": "models/s1-mini/README.md",
            "recipes": [
                {
                    "name": "s1-mini",
                    "status": "verified",
                    "source_model": "simplescaling/s1-mini",
                    "hf_repo": "mlboydaisuke/S1-mini-CoreAI",
                    "bundle": "s1_mini_float32.aimodel",
                    "steps": 1
                }
            ],
            "repos": [
                {"id": "mlboydaisuke/S1-mini-CoreAI", "downloads_30d": 1965, "bundles": ["s1_mini_float32.aimodel"]}
            ]
        },
        {
            "family": "draft-family",
            "card": "models/draft-family/README.md",
            "recipes": [
                {
                    "name": "draft-recipe",
                    "status": "draft",
                    "hf_repo": "mlboydaisuke/Draft-CoreAI",
                    "bundle": "draft_float32.aimodel",
                    "steps": 1
                }
            ],
            "repos": []
        },
        {
            "family": "no-bundle-family",
            "card": "models/no-bundle-family/README.md",
            "recipes": [
                {
                    "name": "no-bundle-recipe",
                    "status": "verified",
                    "hf_repo": "mlboydaisuke/NoBundle-CoreAI",
                    "bundle": null,
                    "steps": 1
                }
            ],
            "repos": []
        }
    ]
}
"""

@Suite("CoreAIModelZooCatalogTests")
struct CoreAIModelZooCatalogTests {
    @Test("Decodes only verified recipes with a published bundle")
    func decodesVerifiedDownloadableRecipes() throws {
        let descriptors = try CoreAIModelZooCatalog.descriptors(from: Data(zooFixtureJSON.utf8))
        #expect(descriptors.count == 1)
        let model = try #require(descriptors.first)
        #expect(model.id == "mlboydaisuke/S1-mini-CoreAI")
        #expect(model.family == "s1-mini")
        #expect(model.publisher == "mlboydaisuke")
        #expect(model.source == .appleCoreAI)
        #expect(model.sourceURL == URL(string: "https://huggingface.co/mlboydaisuke/S1-mini-CoreAI"))
        #expect(model.downloads == 1965)
        #expect(model.variants.count == 1)
        let variant = try #require(model.variants.first)
        #expect(variant.runtime == .coreAI)
        #expect(variant.format == .aimodel)
        #expect(variant.source == .appleCoreAI)
        #expect(variant.downloadURL == nil)
        #expect(variant.resources.first?.relativePath == "s1_mini_float32.aimodel")
    }

    @Test("Invalid index document fails closed")
    func invalidIndexFailsClosed() {
        #expect(throws: ArchonModelsError.invalidResponse) {
            try CoreAIModelZooCatalog.descriptors(from: Data("not json".utf8))
        }
        #expect(throws: ArchonModelsError.invalidResponse) {
            try CoreAIModelZooCatalog.descriptors(from: Data("{}".utf8))
        }
    }

    @Test("Query filters by family and repository")
    func queryFiltering() async throws {
        let catalog = CoreAIModelZooCatalog(
            models: try CoreAIModelZooCatalog.descriptors(from: Data(zooFixtureJSON.utf8))
        )
        #expect(try await catalog.search(ModelSearchRequest(query: "s1-mini")).count == 1)
        #expect(try await catalog.search(ModelSearchRequest(query: "S1-MINI")).count == 1)
        #expect(try await catalog.search(ModelSearchRequest(query: "qwen")).isEmpty)
        #expect(try await catalog.search(ModelSearchRequest(query: "")).count == 1)
    }

    @Test("Runtime and format filters apply to variants only")
    func runtimeFormatFiltering() async throws {
        let catalog = CoreAIModelZooCatalog(
            models: try CoreAIModelZooCatalog.descriptors(from: Data(zooFixtureJSON.utf8))
        )
        let coreAI = try await catalog.search(ModelSearchRequest(query: "", runtime: .coreAI, format: .aimodel))
        #expect(coreAI.first?.variants.count == 1)
        let mlx = try await catalog.search(ModelSearchRequest(query: "", runtime: .mlx, format: .mlx))
        #expect(mlx.first?.variants.isEmpty == true)
    }

    @Test("Pagination honors offset and limit with hasMore")
    func pagination() async throws {
        let descriptors = try CoreAIModelZooCatalog.descriptors(from: Data(zooFixtureJSON.utf8))
        let catalog = CoreAIModelZooCatalog(models: descriptors + descriptors.map {
            ModelDescriptor(
                id: $0.id + "-copy",
                name: $0.name + " copy",
                publisher: $0.publisher,
                family: ($0.family ?? "") + "-copy",
                source: $0.source,
                sourceURL: $0.sourceURL,
                variants: $0.variants,
                downloads: $0.downloads
            )
        })
        let first = try await catalog.searchPage(ModelSearchRequest(query: "", offset: 0, limit: 1))
        #expect(first.models.count == 1)
        #expect(first.hasMore)
        let second = try await catalog.searchPage(ModelSearchRequest(query: "", offset: 1, limit: 1))
        #expect(second.models.count == 1)
        #expect(!second.hasMore)
    }

    @Test("Compatible-only without a device snapshot hides unmeasurable variants")
    func compatibleOnlyWithoutDevice() async throws {
        let catalog = CoreAIModelZooCatalog(
            models: try CoreAIModelZooCatalog.descriptors(from: Data(zooFixtureJSON.utf8))
        )
        let result = try await catalog.search(ModelSearchRequest(query: "", compatibleOnly: true))
        #expect(result.isEmpty)
    }

    @Test("Index endpoint fetch decodes through the injected client")
    func indexEndpointFetch() async throws {
        let catalog = CoreAIModelZooCatalog(
            indexEndpoint: URL(string: "https://example.com/models/index.json")!,
            session: ZooStubHTTPClient(payload: Data(zooFixtureJSON.utf8))
        )
        let models = try await catalog.search(ModelSearchRequest(query: "s1"))
        #expect(models.count == 1)
        #expect(models.first?.variants.first?.runtime == .coreAI)
    }

    @Test("HTTP failure surfaces as a typed error")
    func httpFailureSurfaces() async {
        let catalog = CoreAIModelZooCatalog(
            indexEndpoint: URL(string: "https://example.com/models/index.json")!,
            session: ZooStubHTTPClient(payload: Data(), statusCode: 404)
        )
        await #expect(throws: ArchonModelsError.httpFailure(statusCode: 404)) {
            try await catalog.search(ModelSearchRequest(query: ""))
        }
    }
}
