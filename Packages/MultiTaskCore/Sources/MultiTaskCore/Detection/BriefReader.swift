import Foundation

/// The stated context a project carries, read from the briefs
/// [`project-starter-pack`](https://github.com/joesteinkamp/project-starter-pack)
/// leaves at a repo root.
///
/// The distinction that matters: a README is *scraped* context — the app guesses
/// which paragraph is the point. A brief is *stated* context in known sections,
/// written deliberately. That difference is what separates telling someone what
/// is stuck from suggesting what to do next, so everything here is a plain
/// section read with no inference.
public struct ProductBrief: Codable, Hashable, Sendable {
    /// A single sentence a stranger could repeat. The canonical Goal.
    public var oneLiner: String?
    /// brand | product | hybrid.
    public var register: String?
    public var purpose: String?
    /// What the product must let people do.
    public var jobsToBeDone: [String]
    /// The closest thing on disk to an acceptance criterion for the project.
    public var successMetrics: [String]
    /// Handed to a reviewer so a review is judged against this project's own
    /// standards rather than generic ones.
    public var designPrinciples: [String]
    public var antiReferences: [String]

    public init(oneLiner: String? = nil, register: String? = nil, purpose: String? = nil,
                jobsToBeDone: [String] = [], successMetrics: [String] = [],
                designPrinciples: [String] = [], antiReferences: [String] = []) {
        self.oneLiner = oneLiner
        self.register = register
        self.purpose = purpose
        self.jobsToBeDone = jobsToBeDone
        self.successMetrics = successMetrics
        self.designPrinciples = designPrinciples
        self.antiReferences = antiReferences
    }

    public var isEmpty: Bool {
        oneLiner == nil && purpose == nil && jobsToBeDone.isEmpty && successMetrics.isEmpty
    }
}

/// Which context files a project has.
///
/// **`PRODUCT.md` used to be a hard gate**, on the reasoning that a project the
/// app cannot help with should name the missing document rather than "quietly
/// guess from a README". That reasoning was wrong twice over. Reading
/// `AGENTS.md`, `CLAUDE.md` or a README is not guessing — those are deliberate
/// statements of what a project is, and most repositories have one. And the
/// effect was that a board of ordinary projects reported "No PRODUCT.md — add
/// one to get suggestions" as their *status*: the app answering "what is
/// happening here?" with a request for paperwork.
///
/// Any of them now counts as knowing what the project is. `PRODUCT.md` still
/// says the most — it is the only one carrying positioning, personas and
/// anti-references — so it is still worth having, just not a toll gate.
public struct BriefSet: Codable, Hashable, Sendable {
    public var product: Bool = false
    public var design: Bool = false
    public var designTokens: Bool = false
    public var code: Bool = false
    public var writing: Bool = false
    public var agents: Bool = false
    /// `CLAUDE.md` — instructions written for an agent, which describe the
    /// project as a side effect.
    public var claude: Bool = false
    /// A README. The weakest of these and by far the most common.
    public var readme: Bool = false

    public init() {}

    /// Whether anything here says what this project is.
    public var meetsMinimum: Bool { product || agents || claude || code || readme }

    /// Whether the *richest* source is present — worth prompting for once, never
    /// worth reporting as a status.
    public var hasProductBrief: Bool { product }

    public var missing: [String] {
        var names: [String] = []
        if !product { names.append("PRODUCT.md") }
        if !design { names.append("DESIGN.md") }
        if !code { names.append("CODE.md") }
        return names
    }
}

/// Reads `PRODUCT.md` and reports which sibling briefs exist.
///
/// Results are cached against file modification time, like `ProjectContextReader`,
/// so this is cheap to call every refresh.
public final class BriefReader: @unchecked Sendable {
    public static let productFile = "PRODUCT.md"

    static let maxBytes = 128 * 1024

    private struct CacheEntry {
        var signature: String
        var brief: ProductBrief
        var set: BriefSet
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init() {}

    /// - Returns: the parsed brief (nil when there is no usable `PRODUCT.md`)
    ///   and which briefs the project carries.
    public func read(projectPath: String) -> (brief: ProductBrief?, set: BriefSet) {
        let base = URL(fileURLWithPath: projectPath, isDirectory: true)
        let productURL = base.appendingPathComponent(Self.productFile)

        var set = BriefSet()
        set.product = FileSupport.exists(productURL)
        set.design = FileSupport.exists(base.appendingPathComponent("DESIGN.md"))
        set.designTokens = FileSupport.exists(base.appendingPathComponent("DESIGN.json"))
        set.code = FileSupport.exists(base.appendingPathComponent("CODE.md"))
        set.writing = FileSupport.exists(base.appendingPathComponent("WRITING.md"))
        set.agents = FileSupport.exists(base.appendingPathComponent("AGENTS.md"))
        set.claude = FileSupport.exists(base.appendingPathComponent("CLAUDE.md"))
        set.readme = FileSupport.exists(base.appendingPathComponent("README.md"))
            || FileSupport.exists(base.appendingPathComponent("readme.md"))

        guard set.product else { return (nil, set) }

        let signature = "\(FileSupport.modificationDate(of: productURL).timeIntervalSince1970)"
        lock.lock()
        if let entry = cache[projectPath], entry.signature == signature {
            lock.unlock()
            return (entry.brief.isEmpty ? nil : entry.brief, set)
        }
        lock.unlock()

        guard let text = FileSupport.readHead(of: productURL, limit: Self.maxBytes) else {
            return (nil, set)
        }
        let brief = Self.parse(text)

        lock.lock()
        cache[projectPath] = CacheEntry(signature: signature, brief: brief, set: set)
        lock.unlock()

        return (brief.isEmpty ? nil : brief, set)
    }

    /// Parses a `PRODUCT.md` body.
    ///
    /// Reading the *first paragraph* of this file — which is what the goal
    /// heuristic did before briefs were understood — lands on the **Register**
    /// section, because the title and the generated blockquote above it are both
    /// skipped as chrome. A starter-pack project would therefore show
    /// "product — a daily-use reading tool…" where its one-liner belongs. Hence
    /// section-addressed reading rather than positional.
    public static func parse(_ text: String) -> ProductBrief {
        var brief = ProductBrief()

        brief.oneLiner = Markdown.section("One-liner", in: text).flatMap(Markdown.firstParagraph(of:))
            ?? Markdown.section("One liner", in: text).flatMap(Markdown.firstParagraph(of:))
        brief.register = Markdown.section("Register", in: text).flatMap(Markdown.firstParagraph(of:))
        brief.purpose = Markdown.section("Product Purpose", in: text).flatMap(Markdown.firstParagraph(of:))
            ?? Markdown.section("Purpose", in: text).flatMap(Markdown.firstParagraph(of:))

        brief.jobsToBeDone = Markdown.section("Jobs-to-be-done", in: text).map(Markdown.bullets(in:))
            ?? Markdown.section("Jobs to be done", in: text).map(Markdown.bullets(in:))
            ?? []
        brief.successMetrics = Markdown.section("Success metrics", in: text).map(Markdown.bullets(in:)) ?? []
        brief.designPrinciples = Markdown.section("Design Principles", in: text).map(Markdown.bullets(in:)) ?? []
        brief.antiReferences = Markdown.section("Anti-references", in: text).map(Markdown.bullets(in:)) ?? []

        // A template that was never filled in leaves its slots behind. Treat an
        // unsubstituted placeholder as absent rather than as content.
        if let one = brief.oneLiner, Self.isPlaceholder(one) { brief.oneLiner = nil }
        if let reg = brief.register, Self.isPlaceholder(reg) { brief.register = nil }
        if let purpose = brief.purpose, Self.isPlaceholder(purpose) { brief.purpose = nil }
        brief.jobsToBeDone.removeAll(where: Self.isPlaceholder)
        brief.successMetrics.removeAll(where: Self.isPlaceholder)
        brief.designPrinciples.removeAll(where: Self.isPlaceholder)
        brief.antiReferences.removeAll(where: Self.isPlaceholder)

        return brief
    }

    static func isPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("{{") && value.hasSuffix("}}")
    }
}
