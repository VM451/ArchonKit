import Foundation
#if canImport(SwiftDataMacros)
import SwiftData
#endif

/// The entry point for local stealth crawl and extraction in ArchonSearch.
/// For ArchonSearch 2.0 web-grounded retrieval and autonomous research, use `ArchonSearchClient`.
public final class ArchonSearch: Sendable {
    internal let discoveryEngine: DiscoveryEngine
    internal let semanticCore: ArchonSemanticCore
    internal let structuredExtractionHandler: StructuredExtractionHandler?
#if canImport(SwiftDataMacros)
    internal let modelContainer: ModelContainer?
#endif
    internal let queueActor: FrontierQueueActor?
    internal let initializationFailure: String?
    internal let localWorkspaceRoots: [URL]
    
    /// Initializes a new ArchonSearch instance.
    /// By default, initializes an in-memory SwiftData database for crawling.
    public init(
        structuredExtractionHandler: StructuredExtractionHandler? = nil,
        localWorkspaceRoots: [URL] = []
    ) {
        self.localWorkspaceRoots = localWorkspaceRoots
        self.discoveryEngine = DiscoveryEngine(localWorkspaceRoots: localWorkspaceRoots)
        self.semanticCore = ArchonSemanticCore(structuredExtractionHandler: structuredExtractionHandler)
        self.structuredExtractionHandler = structuredExtractionHandler
        
#if canImport(SwiftDataMacros)
        let container: ModelContainer?
        let initializationFailure: String?
        do {
            let schema = Schema([CrawlNode.self, ScrapedPage.self])
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            initializationFailure = nil
        } catch {
            container = nil
            initializationFailure = String(describing: error)
        }
        self.modelContainer = container
        self.queueActor = container.map { FrontierQueueActor(modelContainer: $0) }
        self.initializationFailure = initializationFailure
#else
        self.queueActor = FrontierQueueActor()
        self.initializationFailure = nil
        _ = localWorkspaceRoots
#endif
    }
}
