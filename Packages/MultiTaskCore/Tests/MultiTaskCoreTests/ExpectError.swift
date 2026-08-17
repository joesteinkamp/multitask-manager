import Foundation
import Testing

/// Runs `body` and returns the error it threw, or fails the test.
///
/// `#expect(throws:)` only began *returning* the thrown error in a later
/// swift-testing than the one Swift 6.0 ships, and this package declares
/// swift-tools-version 6.0 — so using that return value compiled locally and
/// broke the Linux CI container. This keeps the assertions that inspect an
/// error's code portable across both.
func expectError<E: Error>(_ type: E.Type, _ body: () throws -> Void,
                           sourceLocation: SourceLocation = #_sourceLocation) -> E? {
    do {
        try body()
        Issue.record("Expected \(type) to be thrown, but nothing was",
                     sourceLocation: sourceLocation)
        return nil
    } catch let error as E {
        return error
    } catch {
        Issue.record("Expected \(type), got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// The async form.
func expectError<E: Error>(_ type: E.Type, _ body: () async throws -> Void,
                           sourceLocation: SourceLocation = #_sourceLocation) async -> E? {
    do {
        try await body()
        Issue.record("Expected \(type) to be thrown, but nothing was",
                     sourceLocation: sourceLocation)
        return nil
    } catch let error as E {
        return error
    } catch {
        Issue.record("Expected \(type), got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}
