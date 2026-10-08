import AppKit
import Combine

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Temporary holding area for dragged files. Items live in memory for the session.
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Driven by the window-level drop handling in `PassthroughHostingView`, not SwiftUI's
    /// `.onDrop`, which would register its drop target too late for an in-flight drag.
    @Published var isDropTargeted = false

    func add(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        items.append(ShelfItem(url: url))
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }
}
