import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: ShelfModel
    private var targeted: Bool { shelf.isDropTargeted }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .foregroundStyle(.white.opacity(targeted ? 0.6 : 0.18))

            if shelf.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 18))
                    Text("Drop files here")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            itemView(item)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(height: 66)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.08 : 0.0))
        )
    }

    private func itemView(_ item: ShelfItem) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 34, height: 34)
            Text(item.name)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 48)
        }
        .overlay(ShelfItemDragSource(item: item, shelf: shelf))
    }
}

/// AppKit drag source for a shelf item. SwiftUI's `.onDrag` never reports how the drag session
/// ended, and removing an item once it lands somewhere requires exactly that signal —
/// `draggingSession(_:endedAt:operation:)`. The right-click menu lives here too, because this
/// view sits above the SwiftUI content and intercepts those clicks either way.
private struct ShelfItemDragSource: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfModel

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.item = item
        view.shelf = shelf
    }
}

private final class DragSourceView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var shelf: ShelfModel?
    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, let start = mouseDownEvent else { return }
        let from = convert(start.locationInWindow, from: nil)
        let to = convert(event.locationInWindow, from: nil)
        guard hypot(to.x - from.x, to.y - from.y) > 3 else { return }
        mouseDownEvent = nil

        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let iconFrame = NSRect(x: bounds.midX - 17, y: bounds.midY - 17, width: 34, height: 34)
        dragItem.setDraggingFrame(iconFrame, contents: item.icon)
        beginDraggingSession(with: [dragItem], event: start, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Nothing in-app accepts shelf items — a within-app mask of [] keeps a drop back onto
        // the shelf from re-adding the item just before the removal below runs.
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : []
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        mouseDownEvent = nil
        // `[]` means the drag was cancelled or poofed; anything else means it landed.
        guard operation != [], let item else { return }
        shelf?.remove(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Remove", action: #selector(removeFromShelf), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func reveal() {
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func removeFromShelf() {
        guard let item else { return }
        shelf?.remove(item)
    }
}
