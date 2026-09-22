import Foundation
import Combine

/// Lightweight status reporting.
///
/// A menu bar app that silently does nothing is impossible to debug from the
/// outside — you cannot tell "not trusted" from "trusted but found no windows"
/// from "placed them and something moved them back". Every interesting event
/// goes to the unified log (`log show --predicate 'process == "Macnizer"'`) and
/// to a small ring buffer the panel displays.
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published var engineRunning = false
    @Published var lastRetile: Date?
    @Published var managedCount = 0

    private let limit = 40

    private init() {}

    func log(_ message: String) {
        NSLog("Macnizer: %@", message)
        DispatchQueue.main.async {
            self.entries.insert(Entry(at: Date(), text: message), at: 0)
            if self.entries.count > self.limit { self.entries.removeLast() }
        }
    }
}
