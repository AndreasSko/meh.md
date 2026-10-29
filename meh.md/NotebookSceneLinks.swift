import Foundation
import NoteCore
import SwiftUI

#if os(iOS)
    import UIKit
#endif

struct NotebookLinkRoute: Hashable {
    let id = UUID()
    let noteID: UUID
}

#if os(iOS)
struct NotebookLinkVisitPreview {
    let text: String
    let position: MarkdownEditorPosition?
    let viewportInsets: UIEdgeInsets?
    let viewportOriginY: CGFloat?
    let titleHeight: CGFloat
}
#endif

enum NotebookLinkUIError: LocalizedError {
    case changed, unsupported, missingFragment, missingFolder
    var errorDescription: String? {
        switch self {
        case .changed: "This link changed. Open it again to use its current destination."
        case .unsupported: "This link points to content that meh.md does not support yet."
        case .missingFragment: "The note opened, but its linked heading or block could not be found."
        case .missingFolder: "Create the destination folder in Files before creating this linked note."
        }
    }
}

/// Following links, Back and Forward, backlinks, and link completion.
extension NotebookSceneState {
    func configureLinkNavigation(openURL: OpenURLAction) {
        let navigation = editorNavigation
        navigation.openLink = { [weak self] link in
            self?.openNoteLink(link, openURL: openURL)
        }
        navigation.requestLink = { [weak self, weak navigation] text, range in
            guard let self, let selectedID, !busy else { return }
            let existing = NotebookLinkParser.parse(text).first {
                !$0.isEmbed && (NSIntersectionRange($0.range, range).length > 0
                    || NSLocationInRange(range.location, $0.range))
            }
            let selectedText = (text as NSString).substring(with: range)
            linkInsertion = NotebookLinkInsertionRequest(
                sourceID: selectedID, text: text,
                range: existing?.range ?? range,
                label: existing?.label ?? selectedText)
            dismissEditorCompletion()
            navigation?.hasLinkCompletion = false
        }
        navigation.completionCommand = { [weak self, weak navigation] command in
            guard let self else { return false }
            if let completion = variableCompletion {
                guard canCompleteSnippetVariable, navigation === editorNavigation else {
                    dismissEditorCompletion()
                    return false
                }
                switch command {
                case "dismiss": dismissEditorCompletion()
                case "accept":
                    guard let selectedID, !completion.suggestions.isEmpty else { return false }
                    insertCompletedVariable(
                        completion.suggestions[min(linkCompletionSelection,
                            completion.suggestions.count - 1)],
                        completion: completion, textSnapshot: linkCompletionText,
                        sourceID: selectedID, selection: variableCompletionSelection,
                        navigation: editorNavigation)
                case "next":
                    linkCompletionSelection = min(max(0, completion.suggestions.count - 1),
                        linkCompletionSelection + 1)
                case "previous": linkCompletionSelection = max(0, linkCompletionSelection - 1)
                default: return false
                }
                return true
            }
            guard let completion = linkCompletion else { return false }
            let suggestions = links.suggestions(for: completion.query)
            let headings = completionHeadings
            let isHeading = completion.query.contains("#")
            let count = isHeading ? headings.count : suggestions.count
            switch command {
            case "dismiss":
                dismissEditorCompletion()
                navigation?.hasLinkCompletion = false
            case "accept":
                guard count > 0 else { return false }
                if isHeading, let target = completionHeadingTarget {
                    let heading = headings[min(linkCompletionSelection, headings.count - 1)]
                    insertCompletedLink(to: target,
                        fragment: NotebookLinkDestination.wikiHeadingFragment(heading))
                } else {
                    insertCompletedLink(to: suggestions[min(linkCompletionSelection, suggestions.count - 1)])
                }
            case "next":
                linkCompletionSelection = min(max(0, count - 1), linkCompletionSelection + 1)
            case "previous":
                linkCompletionSelection = max(0, linkCompletionSelection - 1)
            default: return false
            }
            return true
        }
        navigation.selectionChanged = { [weak self, weak navigation] text, range, editing in
            guard let self else { return }
            guard navigation === editorNavigation, editing, !busy, historyBrowser == nil,
                  let session, session.isEditingEnabled,
                  text.utf8.elementsEqual(session.text.utf8), linkInsertion == nil else {
                dismissEditorCompletion()
                navigation?.hasLinkCompletion = false
                return
            }
            let variable = canCompleteSnippetVariable
                ? NotebookSnippetVariableCompletion.detect(in: text, selection: range) : nil
            if variable?.query != variableCompletion?.query { linkCompletionSelection = 0 }
            if variableCompletion != variable { variableCompletion = variable }
            if variable != nil { variableCompletionSelection = range }
            let completion = variable == nil
                ? NotebookLinkCompletion.detect(in: text, selection: range) : nil
            if completion?.query != linkCompletion?.query { linkCompletionSelection = 0 }
            linkCompletion = completion
            navigation?.hasLinkCompletion = completion != nil || variable != nil
            // Only an active completion needs a source snapshot. Publishing
            // the whole note here otherwise redraws this scene on every key.
            if completion != nil || variable != nil { linkCompletionText = text }
        }
    }

    var canGoBack: Bool {
        historyBrowser == nil && !busy && linkHistory.backTarget != nil
    }

    // MARK: Completion

    var canCompleteSnippetVariable: Bool {
        guard let selectedID, !busy, historyBrowser == nil,
              session?.isEditingEnabled == true else { return false }
        return snippetSourceNoteIDs.contains(selectedID)
    }

    func dismissEditorCompletion() {
        linkCompletion = nil
        variableCompletion = nil
        editorNavigation.hasLinkCompletion = false
    }

    func insertCompletedVariable(_ variable: NotebookSnippetVariable,
        completion: NotebookSnippetVariableCompletion, textSnapshot: String,
        sourceID: UUID, selection: NSRange, navigation: MarkdownEditorNavigation) {
        guard sourceID == selectedID, navigation === editorNavigation,
              navigation.isValid, canCompleteSnippetVariable,
              replica.snippets.contains(where: { $0.id == sourceID }),
              session?.text == textSnapshot,
              navigation.capturePosition?()?.selection == selection else { return }
        let change = MarkdownEditingChange(range: completion.range,
            replacement: variable.token,
            selection: NSRange(location: completion.range.location + variable.token.utf16.count,
                length: 0))
        if navigation.insertLink?(change, textSnapshot) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        dismissEditorCompletion()
    }

    var completionHeadingTarget: NotebookLinkNote? {
        guard let completion = linkCompletion, completion.query.contains("#"),
              let selectedID else { return nil }
        let path = NotebookLinkParser.literalDestinationParts(completion.query).path
        let probe = "[[\(path.isEmpty ? "#__heading" : path)]]"
        guard let occurrence = NotebookLinkParser.parse(probe).first,
              case .resolved(let id, _) = NotebookLinkResolver.resolve(
                occurrence, sourceID: selectedID, notes: replica.linkNotes)
        else { return nil }
        return replica.linkNotes.first { $0.id == id }
    }

    var completionHeadings: [String] {
        guard let target = completionHeadingTarget, let completion = linkCompletion else { return [] }
        let fragment = NotebookLinkParser.literalDestinationParts(completion.query).fragment ?? ""
        let headings = target.id == selectedID
            ? NotebookLinkParser.headings(in: linkCompletionText)
            : links.headingNames[target.id] ?? []
        return headings.filter { fragment.isEmpty || $0.localizedCaseInsensitiveContains(fragment) }
    }

    func insertCompletedLink(to target: NotebookLinkNote, fragment: String? = nil,
                             completionSnapshot: NotebookLinkCompletion? = nil,
                             textSnapshot: String? = nil, sourceID: UUID? = nil) {
        // A touch on the suggestion list can end native text input before the
        // button action arrives. Use that row's captured authoring intent;
        // the editor's text/revision guards still reject stale insertions.
        guard let completion = completionSnapshot ?? linkCompletion,
              let sourceID = sourceID ?? selectedID, sourceID == selectedID,
              let source = replica.linkNotes.first(where: { $0.id == sourceID }),
              let currentTarget = replica.linkNotes.first(where: { $0.id == target.id }),
              let destination = NotebookLinkDestination.make(target: currentTarget, source: source,
                kind: .wiki,
                fragment: fragment ?? NotebookLinkParser.literalDestinationParts(completion.query).fragment,
                includeExtension: false) else { return }
        let alias = links.alias(for: completion.query, noteID: target.id)
        let escapedAlias = alias.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
        }
        let replacement = "[[\(destination)\(escapedAlias.map { "|" + $0 } ?? "")]]"
        let change = MarkdownEditingChange(range: completion.range, replacement: replacement,
            selection: NSRange(location: completion.range.location + replacement.utf16.count, length: 0))
        if editorNavigation.insertLink?(change, textSnapshot ?? linkCompletionText) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        dismissEditorCompletion()
        editorNavigation.hasLinkCompletion = false
    }

    func insertPickedLink(to target: NotebookLinkNote,
                          request: NotebookLinkInsertionRequest) {
        guard let source = replica.linkNotes.first(where: { $0.id == request.sourceID }),
              let currentTarget = replica.linkNotes.first(where: { $0.id == target.id }),
              let destination = NotebookLinkDestination.make(target: currentTarget,
                source: source, kind: .markdown) else { return }
        insertPickedURL(destination, request: request,
            defaultLabel: NotebookNoteName.title(from: target.name))
    }

    func insertPickedURL(_ destination: String, request: NotebookLinkInsertionRequest,
                         defaultLabel: String = "Link") {
        guard selectedID == request.sourceID else { return }
        let label = (request.label.isEmpty ? defaultLabel : request.label)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let safeDestination = destination
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        let replacement = "[\(label)](\(safeDestination))"
        let change = MarkdownEditingChange(range: request.range, replacement: replacement,
            selection: NSRange(location: request.range.location + replacement.utf16.count, length: 0))
        if editorNavigation.insertLink?(change, request.text) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        linkInsertion = nil
    }

    func linkInsertionDismissed() {
        editorNavigation.resumeEditing?()
        editorNavigation.focusEditor?()
    }

    // MARK: Visits

    private func currentLinkVisit() -> NotebookLinkNavigationHistory.Visit? {
        guard let selectedID else { return nil }
        let position = editorNavigation.capturePosition?().flatMap {
            try? JSONEncoder().encode($0)
        }
        return .init(noteID: selectedID, position: position)
    }

    func resetLinkJourney() {
        linkJourneyID = UUID()
        backlinkDeparture = nil
        linkHistory.clear()
        #if os(iOS)
        linkRoutes = []
        linkVisitPreviews = [:]
        restoringLinkRouteID = nil
        linkRootRoute = selectedID.map { NotebookLinkRoute(noteID: $0) }
        activeLinkRouteID = linkRootRoute?.id
        #endif
    }

    private func rememberLinkVisitPreview(route: NotebookLinkRoute? = nil) {
        #if os(iOS)
        guard let route = route ?? linkRoutes.last ?? linkRootRoute, let session else { return }
        linkVisitPreviews[route.id] = NotebookLinkVisitPreview(
            text: session.text, position: editorNavigation.capturePosition?(),
            viewportInsets: editorNavigation.captureViewportInsets?(),
            viewportOriginY: editorNavigation.captureViewportOriginY?(),
            titleHeight: detailTitleHeight
        )
        #endif
    }

    #if os(iOS)
    func navigateLinkRoutes(to routes: [NotebookLinkRoute],
                            onReturn: (@MainActor () -> Void)? = nil) {
        guard !busy, routes.count < linkRoutes.count,
              Array(linkRoutes.prefix(routes.count)) == routes else { return }
        let steps = linkRoutes.count - routes.count
        guard linkHistory.backTarget(steps: steps) != nil else { return }
        // Accept the native pop immediately. Keeping the old path during an
        // asynchronous save makes NavigationStack undo and replay the pop.
        let previousRoutes = linkRoutes
        rememberLinkVisitPreview()
        linkRoutes = routes
        navigateLinkHistory(back: true, steps: steps, compactRoutesBeforePop: previousRoutes,
                            onReturn: onReturn)
    }
    #endif

    func showBacklinks() {
        perform { [self] in
            try await flushEditor()
            dismissEditorCompletion()
            editorNavigation.hasLinkCompletion = false
            // A presented sheet changes the underlying editor's viewport.
            // Back should return to the reading position before presentation.
            backlinkDeparture = currentLinkVisit()
            rememberLinkVisitPreview()
            if let selectedID { links.prepareBacklinks(replica: replica, targetID: selectedID) }
            showingBacklinks = true
        }
    }

    private func openNoteLink(_ occurrence: NotebookLinkOccurrence, openURL: OpenURLAction) {
        guard let sourceID = selectedID else { return }
        perform { [self] in
            try await flushEditor()
            guard sourceID == selectedID,
                  NotebookLinkParser.parse(session?.text ?? "").contains(occurrence)
            else { throw NotebookLinkUIError.changed }
            let notes = replica.linkNotes
            switch NotebookLinkResolver.resolve(occurrence, sourceID: sourceID, notes: notes) {
            case .resolved(let targetID, let fragment):
                try await visitLinkedNote(targetID, fragment: fragment)
            case .ambiguous(let ids):
                linkChoices = notes.filter { ids.contains($0.id) }
                linkChoiceFragment = NotebookLinkResolver.fragment(of: occurrence)
            case .missing:
                missingLink = occurrence
            case .external(let url):
                openURL(url)
            case .unsupported:
                throw NotebookLinkUIError.unsupported
            }
        }
    }

    func chooseLinkedNote(_ note: NotebookLinkNote) {
        linkChoices = []
        perform { [self] in try await visitLinkedNote(note.id, fragment: linkChoiceFragment) }
    }

    func visitLinkedNote(_ id: UUID, fragment: String?,
                         occurrence: NotebookLinkOccurrence? = nil,
                         targetID: UUID? = nil) async throws {
        try await flushEditor()
        if let occurrence, let targetID {
            let opened = try await replica.openNote(id)
            guard currentBacklinkRange(occurrence, sourceID: id, targetID: targetID,
                text: opened.text) != nil else { throw NotebookLinkUIError.changed }
        }
        let sheetDeparture = occurrence != nil && targetID == selectedID
            && backlinkDeparture?.noteID == selectedID ? backlinkDeparture : nil
        let previous = sheetDeparture ?? currentLinkVisit()
        if sheetDeparture == nil { rememberLinkVisitPreview() }
        rememberEditorPosition()
        try await selectNote(id, linkVisit: true)
        guard selectedID == id else { return }
        revealLinkedNoteInFiles(id)
        if let previous { linkHistory.recordDeparture(previous) }
        #if os(iOS)
        let retainedRoutes = Set(linkRoutes.map(\.id) + [linkRootRoute?.id].compactMap { $0 })
        linkVisitPreviews = linkVisitPreviews.filter { retainedRoutes.contains($0.key) }
        linkRoutes.append(NotebookLinkRoute(noteID: id))
        activeLinkRouteID = linkRoutes.last?.id
        if linkRoutes.count > linkHistory.limit {
            if let oldRoot = linkRootRoute { linkVisitPreviews[oldRoot.id] = nil }
            linkRootRoute = linkRoutes.removeFirst()
        }
        #endif
        dismissEditorCompletion()
        let incoming = editorNavigation
        incoming.hasExplicitVisitDestination = true
        incoming.whenAttached { [weak self, weak incoming] in
            guard let self, let incoming, selectedID == id, let text = session?.text
            else { return }
            var destination: NSRange?
            if let occurrence, let targetID {
                destination = currentBacklinkRange(occurrence, sourceID: id,
                    targetID: targetID, text: text)
                guard destination != nil else {
                    errorMessage = NotebookLinkUIError.changed.localizedDescription
                    return
                }
            } else if let fragment {
                destination = NotebookLinkParser.targetRange(for: fragment, in: text)
                if destination == nil { errorMessage = NotebookLinkUIError.missingFragment.localizedDescription }
            }
            // Plain links open at the start; returning restores the visit position.
            incoming.revealSearchMatch?(destination ?? NSRange(location: 0, length: 0))
        }
    }

    private func currentBacklinkRange(_ occurrence: NotebookLinkOccurrence,
                                      sourceID: UUID, targetID: UUID, text: String) -> NSRange? {
        let current = NotebookLinkParser.parse(text).filter {
            if case .resolved(let resolved, _) = NotebookLinkResolver.resolve(
                $0, sourceID: sourceID, notes: replica.linkNotes) { return resolved == targetID }
            return false
        }
        if let exact = current.first(where: { $0 == occurrence }) { return exact.range }
        let matching = current.filter {
            $0.destination == occurrence.destination && $0.label == occurrence.label
        }
        return matching.count == 1 ? matching[0].range : nil
    }

    /// `onReturn` runs once the destination has restored its position.
    func navigateLinkHistory(back: Bool, steps: Int = 1,
                             compactRoutesBeforePop: [NotebookLinkRoute]? = nil,
                             onReturn: (@MainActor () -> Void)? = nil) {
        let target = back ? linkHistory.backTarget(steps: steps) : linkHistory.forwardTarget
        guard let target else { return }
        let journeyID = linkJourneyID
        perform { [self] in
            do {
                try await flushEditor()
                guard linkJourneyID == journeyID else { return }
                guard let current = currentLinkVisit() else { return }
                rememberLinkVisitPreview(route: compactRoutesBeforePop?.last)
                try await selectNote(target.noteID,
                                     revealDetail: !isCompact, linkVisit: true)
                guard linkJourneyID == journeyID else { return }
                guard selectedID == target.noteID else { throw NotebookLinkUIError.changed }
                revealLinkedNoteInFiles(target.noteID)
                if back { linkHistory.commitBack(current: current, steps: steps) }
                else { linkHistory.commitForward(current: current) }
                #if os(iOS)
                if back {
                    if compactRoutesBeforePop == nil {
                        linkRoutes.removeLast(min(steps, linkRoutes.count))
                    }
                } else {
                    linkRoutes.append(NotebookLinkRoute(noteID: target.noteID))
                }
                let incomingRoute = linkRoutes.last ?? linkRootRoute
                if session?.isEditingEnabled == true, let incomingRoute,
                   target.position != nil, linkVisitPreviews[incomingRoute.id] != nil {
                    // Keep the already-positioned transition preview until
                    // TextKit finishes restoring the replacement editor.
                    restoringLinkRouteID = incomingRoute.id
                } else {
                    restoringLinkRouteID = nil
                }
                activeLinkRouteID = incomingRoute?.id
                // Popped screens remain alive through UIKit's transition. Keep
                // their previews until the next push or a fresh journey.
                #endif
                let incoming = editorNavigation
                incoming.hasExplicitVisitDestination = true
                #if os(iOS)
                let restorationRouteID = restoringLinkRouteID
                #endif
                incoming.whenAttached { [weak self, weak incoming] in
                    guard let self, let incoming, selectedID == target.noteID else { return }
                    let finishRestoration: () -> Void = { [self] in
                        #if os(iOS)
                        guard incoming === editorNavigation, linkJourneyID == journeyID,
                              restoringLinkRouteID == restorationRouteID else { return }
                        restoringLinkRouteID = nil
                        #endif
                        onReturn?()
                    }
                    if let data = target.position,
                       let position = try? JSONDecoder().decode(MarkdownEditorPosition.self, from: data) {
                        // Restoring is asynchronous; `onReturn` needs the
                        // restored selection, not the editor's initial one.
                        if let restore = incoming.restorePositionAndNotify {
                            restore(position, finishRestoration)
                        } else {
                            incoming.restorePosition?(position)
                            finishRestoration()
                        }
                    } else {
                        finishRestoration()
                    }
                }
            } catch {
                #if os(iOS)
                if linkJourneyID == journeyID {
                    restoringLinkRouteID = nil
                    if let compactRoutesBeforePop {
                        // Failed saves leave the visit/history intact and
                        // return to its original screen without losing text.
                        linkRoutes = compactRoutesBeforePop
                    }
                }
                #endif
                throw error
            }
        }
    }

    func openBacklink(_ backlink: NotebookBacklink, targetID: UUID) {
        perform { [self] in
            try await visitLinkedNote(backlink.sourceID, fragment: nil,
                occurrence: backlink.occurrence, targetID: targetID)
            showingBacklinks = false
        }
    }

    func createMissingLinkedNote(_ link: NotebookLinkOccurrence) {
        guard let sourceID = selectedID else { return }
        perform { [self] in
            try await flushEditor()
            let notes = replica.linkNotes
            guard case .missing = NotebookLinkResolver.resolve(link, sourceID: sourceID,
                notes: notes), let source = notes.first(where: { $0.id == sourceID })
            else { throw NotebookLinkUIError.changed }
            let path = NotebookLinkResolver.path(of: link)
            let explicitRelative = path.hasPrefix("./") || path.hasPrefix("../")
            let base = link.kind == .markdown || explicitRelative ? source.path : (source.rootPath ?? "")
            var components = base.split(separator: "/").map(String.init)
            for part in path.split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
                    guard !components.isEmpty else { throw NotebookLinkUIError.unsupported }
                    components.removeLast()
                } else { components.append(String(part)) }
            }
            guard var name = components.popLast(), !name.isEmpty else { throw NotebookLinkUIError.unsupported }
            if !name.lowercased().hasSuffix(".md") && !name.lowercased().hasSuffix(".markdown") { name += ".md" }
            var parentID: UUID?
            for folder in components {
                let matches = replica.placements.filter {
                    $0.item.kind == .folder && !$0.isInTrash
                        && $0.parentID == parentID && $0.displayName == folder
                }
                guard matches.count == 1 else { throw NotebookLinkUIError.missingFolder }
                parentID = matches[0].item.id
            }
            let id = try await replica.createNote(name: name, parentID: parentID)
            missingLink = nil
            try await visitLinkedNote(id, fragment: nil)
        }
    }
}
