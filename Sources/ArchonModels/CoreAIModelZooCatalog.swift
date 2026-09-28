import Foundation
import ArchonCore

/// Dependency-free catalog adapter for the Core AI model zoo
/// ([coreai-model-zoo](https://github.com/john-rocky/coreai-model-zoo)).
///
/// The zoo is a model-artifact catalog, not a SwiftPM package: its
/// machine-readable `models/index.json` lists verified Core AI (`.aimodel`)
/// conversion recipes published as Hugging Face repositories (for example
/// `mlboydaisuke/Nemotron-3-Nano-4B-CoreAI`). This adapter maps each verified,
/// downloadable recipe to a `ModelDescriptor` with `.coreAI`/`.aimodel`
/// variants, so hosts can discover, download, and lifecycle-manage those
/// bundles through the normal `ArchonModels` validation and install path.
///
/// Fail-closed mapping rules:
///
/// - Only recipes with `status == "verified"` become variants. Draft,
///   unverified, or recipe-only entries without a published bundle are
///   skipped; nothing reconstructs a runnable artifact from card prose.
/// - Only recipes with a non-empty `hf_repo` and a non-empty `bundle` become
///   variants. Entries with no published bundle (empty `repos`, null bundle)
///   are skipped.
/// - Variants carry no `downloadURL`. Hosts resolve bundle bytes through
///   `HuggingFaceCatalog.inspect(repositoryID:)` or a host-owned
///   [swift-huggingface](https://github.com/huggingface/swift-huggingface)
///   `HubClient`; this catalog never invents bundle byte URLs.
/// - Descriptor tasks default to `[.textGeneration]`. The zoo index carries
///   no per-model task contract, and Archon never infers tasks from family
///   names. Hosts serving vision/audio zoo entries must refine tasks from
///   the model card before routing.
///
/// This is a lower-level developer catalog. It must never be wrapped in
/// `MLXModelCatalog` or `OfficialModelCatalog`: user-facing discovery stays
/// official-publisher MLX-only, and Core AI entries are excluded from those
/// boundaries by construction (non-MLX runtime/format).
///
/// Conversion itself (`zoo_convert.py`, `coreai-torch`) is developer-side
/// tooling and never an app runtime requirement.
public struct CoreAIModelZooCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String = "coreai-model-zoo"

    /// Machine-readable zoo catalog. Agents and hosts should start here.
    public static let defaultIndexEndpoint = URL(
        string: "https://raw.githubusercontent.com/john-rocky/coreai-model-zoo/main/models/index.json"
    )!

    private let models: [ModelDescriptor]?
    private let indexEndpoint: URL?
    private let session: (any ModelHTTPClient)?

    /// Uses an already-loaded descriptor set (checked-in fixtures, tests, or
    /// a host-decoded `models/index.json` snapshot). No network is used.
    public init(models: [ModelDescriptor]) {
        self.models = models
        self.indexEndpoint = nil
        self.session = nil
    }

    /// Fetches `models/index.json` from the zoo on every search. The endpoint
    /// is public and needs no credential; hosts may inject a session for
    /// testing or custom transport policy.
    public init(
        indexEndpoint: URL = CoreAIModelZooCatalog.defaultIndexEndpoint,
        session: (any ModelHTTPClient)? = nil
    ) {
        self.models = nil
        self.indexEndpoint = indexEndpoint
        self.session = session
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        let descriptors = try await loadedDescriptors()
        let filtered = descriptors.compactMap { filter($0, for: request) }
        let start = min(request.offset, filtered.count)
        let end = min(filtered.count, start + request.limit)
        let page = Array(filtered[start..<end])
        return ModelCatalogPage(models: page, hasMore: end < filtered.count)
    }

    private func loadedDescriptors() async throws -> [ModelDescriptor] {
        if let models { return models }
        guard let indexEndpoint else { throw ArchonModelsError.invalidResponse }
        try ModelDownloadURLPolicy.validate(indexEndpoint)
        let session = session ?? ModelDownloadURLPolicy.makeSession()
        var urlRequest = URLRequest(url: indexEndpoint)
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: urlRequest)
        guard data.count <= ModelDownloadURLPolicy.maximumResponseBytes else {
            throw ArchonModelsError.invalidResponse
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ArchonModelsError.httpFailure(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try Self.descriptors(from: data)
    }

    private func filter(_ model: ModelDescriptor, for request: ModelSearchRequest) -> ModelDescriptor? {
        if let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let haystack = "\(model.id) \(model.name) \(model.family ?? "")".lowercased()
            guard haystack.contains(query.lowercased()) else { return nil }
        }
        guard request.task == nil || model.tasks.contains(request.task!) else { return nil }
        let filteredVariants = model.variants.filter { variant in
            (request.runtime == nil || variant.runtime == request.runtime) &&
            (request.format == nil || variant.format == request.format) &&
            (!request.compatibleOnly || request.device.map { ModelCompatibilityAnalyzer.analyze(variant: variant, device: $0).canLoad } == true)
        }
        guard !request.compatibleOnly || !filteredVariants.isEmpty else { return nil }
        return ModelDescriptor(
            id: model.id,
            name: model.name,
            publisher: model.publisher,
            family: model.family,
            tasks: model.tasks,
            description: model.description,
            source: model.source,
            sourceURL: model.sourceURL,
            license: model.license,
            variants: request.includeVariants ? filteredVariants : [],
            downloads: model.downloads
        )
    }

    /// Maps one zoo `models/index.json` document to descriptors.
    ///
    /// Throws `ArchonModelsError.invalidResponse` when the document is not a
    /// zoo index. Per-entry gaps (unverified status, missing repository or
    /// bundle) skip that entry rather than failing the whole catalog.
    public static func descriptors(from indexData: Data) throws -> [ModelDescriptor] {
        let decoder = JSONDecoder()
        guard let index = try? decoder.decode(ZooIndex.self, from: indexData) else {
            throw ArchonModelsError.invalidResponse
        }
        return index.models.compactMap(descriptor(for:))
    }

    private static func descriptor(for entry: ZooModelEntry) -> ModelDescriptor? {
        let variants = entry.recipes.compactMap { variant(for: $0, family: entry.family) }
        guard !variants.isEmpty else { return nil }
        let repositoryID = variants[0].modelID
        let publisher = repositoryID.split(separator: "/").first.map(String.init) ?? "Unknown"
        let downloads = entry.repos.compactMap(\.downloads30d).max()
        return ModelDescriptor(
            id: repositoryID,
            name: entry.family,
            publisher: publisher,
            family: entry.family,
            source: .appleCoreAI,
            sourceURL: URL(string: "https://huggingface.co/\(repositoryID)"),
            variants: variants,
            downloads: downloads
        )
    }

    private static func variant(for recipe: ZooRecipe, family: String) -> ModelVariant? {
        guard recipe.status.lowercased() == "verified" else { return nil }
        let repositoryID = recipe.hfRepo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle = recipe.bundle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !repositoryID.isEmpty, !bundle.isEmpty else { return nil }
        return ModelVariant(
            id: "\(repositoryID)#\(recipe.name)",
            name: recipe.name,
            modelID: repositoryID,
            source: .appleCoreAI,
            downloadURL: nil,
            format: .aimodel,
            runtime: .coreAI,
            supportedDeviceArchitectures: ["arm64"],
            supportedPlatforms: Set(ArchonPlatform.allCases),
            resources: [
                ModelResource(name: bundle, relativePath: bundle)
            ]
        )
    }
}

private struct ZooIndex: Decodable {
    let models: [ZooModelEntry]
}

private struct ZooModelEntry: Decodable {
    let family: String
    let recipes: [ZooRecipe]
    let repos: [ZooRepo]

    private enum CodingKeys: String, CodingKey {
        case family, recipes, repos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        family = try container.decode(String.self, forKey: .family)
        recipes = (try? container.decode([ZooRecipe].self, forKey: .recipes)) ?? []
        repos = (try? container.decode([ZooRepo].self, forKey: .repos)) ?? []
    }
}

private struct ZooRecipe: Decodable {
    let name: String
    let status: String
    let hfRepo: String?
    let bundle: String?

    private enum CodingKeys: String, CodingKey {
        case name, status
        case hfRepo = "hf_repo"
        case bundle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        hfRepo = try? container.decodeIfPresent(String.self, forKey: .hfRepo)
        bundle = try? container.decodeIfPresent(String.self, forKey: .bundle)
    }
}

private struct ZooRepo: Decodable {
    let downloads30d: Int?

    private enum CodingKeys: String, CodingKey {
        case downloads30d = "downloads_30d"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloads30d = try? container.decodeIfPresent(Int.self, forKey: .downloads30d)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
