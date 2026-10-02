#!/usr/bin/env python3
"""Check Mac Recents scrollbars offscreen without activating the app.

Compile the actual drawer implementation in a small native fixture. This
covers SwiftUI resetting its List style during animated expansion, which a
static NSScrollView check does not exercise. Requires the project's Xcode SDK.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "meh.md/NotebookMacRecentsExpansion.swift"
FIXTURE = r"""
struct NotebookPlacement {
  struct Item { let id: UUID }
  let item: Item
}
struct RowMarker: NSViewRepresentable {
  let name: String
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.identifier = NSUserInterfaceItemIdentifier(name)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
}
func fixtureRow(_ index: Int, kind: String) -> some View {
  Button {
  } label: {
    NotebookRecentRow(
      title: "Fictional note \(index)",
      preview: "Matching fictional preview",
      isPinned: index == 0, isCurrent: false, showsDivider: true)
  }
  .buttonStyle(.plain)
  .background(RowMarker(name: kind + String(index)))
  .swipeActions(edge: .leading) { Button("Pin") {} }
  .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("Trash") {} }
}

@Observable final class FixtureState { var expanded = false }
struct Fixture: View {
  let state: FixtureState
  let items = (0..<50).map { _ in NotebookPlacement(item: .init(id: UUID())) }
  var body: some View {
    NotebookMacRecentsExpansionHost(
      items: items, selectedNoteID: nil,
      isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 }),
      onSelect: { _ in }, onCollapse: { state.expanded = false }, onVisibleIDs: { _ in },
      rowContent: { placement, index, count in
        fixtureRow(index, kind: "expanded")
      },
      browser: {
        List {
          Section {
            NotebookMacRecentsCompactHeader(isExpanded: true, toggle: {}).anchorPreference(
              key: NotebookMacRecentsAnchorKey.self, value: .bounds
            ) { [$0] }
            ForEach(0..<5, id: \.self) { index in
              fixtureRow(index, kind: "compact").anchorPreference(
                key: NotebookMacRecentsAnchorKey.self, value: .bounds
              ) { [$0] }
            }
            Text("More").anchorPreference(key: NotebookMacRecentsAnchorKey.self, value: .bounds) {
              [$0]
            }
          }.listRowInsets(EdgeInsets())
          ForEach(0..<50, id: \.self) { index in Text("File \(index)") }
        }.scrollIndicators(.automatic)
      })
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
let state = FixtureState()
let host = NSHostingView(rootView: Fixture(state: state))
let window = NSWindow(
  contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 600), styleMask: .borderless,
  backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = host
window.orderBack(nil)
func allScrollViews(_ view: NSView) -> [NSScrollView] {
  var result = (view as? NSScrollView).map { [$0] } ?? []
  result += view.subviews.flatMap { allScrollViews($0) }
  return result
}
func dump(_ label: String) {
  // Sample throughout the animation, rather than only after it settles.
  for _ in 0..<60 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    host.layoutSubtreeIfNeeded()
    for scrollView in allScrollViews(host) {
      precondition(scrollView.scrollerStyle == .overlay, "Legacy frame during " + label)
      precondition(scrollView.verticalScroller?.scrollerStyle == .overlay)
    }
  }
  precondition(allScrollViews(host).count == 2)
  for (index, scrollView) in allScrollViews(host).enumerated() {
    precondition(scrollView.scrollerStyle == .overlay, "Legacy scrollbar after " + label)
    precondition(
      scrollView.verticalScroller?.scrollerStyle == .overlay,
      "Legacy native scroller after " + label)
    print(
      "\(label)[\(index)] style=\(scrollView.scrollerStyle.rawValue) clip=\(scrollView.contentView.bounds.width)"
    )
  }
}
func rowBounds(_ name: String, in view: NSView) -> CGRect? {
  if view.identifier?.rawValue == name { return view.convert(view.bounds, to: host) }
  return view.subviews.compactMap { rowBounds(name, in: $0) }.first
}
dump("Closed")
let compactBounds = rowBounds("compact0", in: host)!
print("CompactRow=\(compactBounds)")
withAnimation(.smooth(duration: 0.3)) { state.expanded = true }
dump("Opened")
let expandedBounds = rowBounds("expanded0", in: host)!
print("ExpandedRow=\(expandedBounds)")
fflush(nil)
precondition(
  abs(compactBounds.minY - expandedBounds.minY) <= 0.5,
  "Row moved vertically on expansion")
precondition(
  abs(compactBounds.minX - expandedBounds.minX) <= 0.5,
  "Row leading padding changed on expansion")
precondition(
  abs(compactBounds.maxX - expandedBounds.maxX) <= 0.5,
  "Row trailing padding changed on expansion")
dump("Settled")
withAnimation(.smooth(duration: 0.3)) { state.expanded = false }
dump("ClosedAgain")
withAnimation(.smooth(duration: 0.3)) { state.expanded = true }
dump("Reopened")
let reopenedBounds = rowBounds("expanded0", in: host)!
precondition(abs(reopenedBounds.minX - compactBounds.minX) <= 0.5)
precondition(abs(reopenedBounds.maxX - compactBounds.maxX) <= 0.5)
let expandedScrollView = allScrollViews(host)[1]
let expandedWidth = expandedScrollView.contentView.bounds.width
expandedScrollView.flashScrollers()
dump("Flashed")
precondition(abs(expandedScrollView.contentView.bounds.width - expandedWidth) < 0.5)
let bottom = max(
  0,
  (expandedScrollView.documentView?.bounds.height ?? 0)
    - expandedScrollView.contentView.bounds.height)
expandedScrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
expandedScrollView.reflectScrolledClipView(expandedScrollView.contentView)
dump("ScrolledToEnd")
expandedScrollView.scrollerStyle = .legacy
// Catch the one-frame legacy flash: correction must finish before returning.
precondition(expandedScrollView.scrollerStyle == .overlay, "Deferred style correction")
precondition(expandedScrollView.verticalScroller?.scrollerStyle == .overlay)
precondition(abs(expandedScrollView.contentView.bounds.width - expandedWidth) < 0.5)
dump("DirectStyleReset")
window.setContentSize(NSSize(width: 280, height: 350))
dump("ShortWindow")
for scrollView in allScrollViews(host) { scrollView.scrollerStyle = .legacy }
NotificationCenter.default.post(
  name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
dump("PreferenceReset")
// The user may switch apps while this runs. Only our activation is a failure.
precondition(
  NSWorkspace.shared.frontmostApplication?.processIdentifier
    != ProcessInfo.processInfo.processIdentifier, "Probe activated its window")
weak var releasedScrollView: NSScrollView?
autoreleasepool {
  let temporaryScrollView = NSScrollView()
  let adapter = NotebookMacOverlayScrollbarView()
  temporaryScrollView.documentView = adapter
  adapter.applyOverlayStyle()
  releasedScrollView = temporaryScrollView
}
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
precondition(releasedScrollView == nil, "Controller retained its scroll view")
print("FullExpansionProbe=PASS")
print("FrontmostUnchanged=\(front == NSWorkspace.shared.frontmostApplication?.processIdentifier)")
window.close()
"""


def main():
    source = SOURCE.read_text()
    source = source.removeprefix("#if os(macOS)\n")
    source = source.replace("import NoteCore\n", "")
    source = source.removesuffix("#endif\n")
    with tempfile.TemporaryDirectory(prefix="meh-recents-scrollbar-") as directory:
        path = Path(directory)
        swift = path / "check.swift"
        binary = path / "check"
        sidebar = (ROOT / "meh.md/NotebookSidebarStyle.swift").read_text()
        swift.write_text(source + sidebar + FIXTURE)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6",
            "-default-isolation", "MainActor", str(swift), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
