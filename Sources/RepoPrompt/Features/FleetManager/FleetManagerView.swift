import SwiftUI

struct FleetManagerView: View {
    @ObservedObject var model: FleetRosterModel
    @ObservedObject var actions: FleetManagerActions
    @State private var collapsed: Set<FleetRosterDisplay.Occurrence> = []

    var body: some View {
        ScrollView {
            // The roster publishes only when it changes; age text must still re-render every tick.
            TimelineView(.periodic(from: .now, by: FleetRosterModel.tickInterval)) { context in
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.roster.sections.isEmpty {
                        let empty = FleetRosterDisplay.emptyState()
                        VStack(spacing: 4) {
                            Text(empty.title).font(.headline)
                            Text(empty.message).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        FleetManagerSummaryView(summary: FleetRosterDisplay.summary(model.roster.sections))
                    }
                    ForEach(model.roster.sections, id: \.windowID) { section in
                        FleetManagerSectionView(
                            section: section,
                            sections: model.roster.sections,
                            actions: actions,
                            collapsed: $collapsed,
                            now: context.date
                        )
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 700, minHeight: 360)
        .popover(isPresented: Binding(
            get: { actions.confirmation != nil },
            set: { if !$0 { actions.cancelDeletion() } }
        )) {
            if let confirmation = actions.confirmation {
                VStack(alignment: .leading, spacing: 12) {
                    Text(confirmation.title).font(.headline)
                    Text(confirmation.message).foregroundStyle(.secondary)
                    if let error = actions.deletionError {
                        Text(error).foregroundStyle(.red)
                    }
                    if actions.isDeletionInFlight {
                        ProgressView("Deleting…")
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { actions.cancelDeletion() }
                            .disabled(actions.isDeletionInFlight)
                        Button("Delete", role: .destructive) {
                            Task { await actions.confirmDeletion() }
                        }
                        .disabled(actions.isDeletionInFlight || actions.deletionError != nil)
                    }
                }
                .padding()
                .frame(width: 360)
                .interactiveDismissDisabled(actions.isDeletionInFlight)
            }
        }
    }
}

private extension FleetRosterDisplay.Tone {
    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .success: .green
        case .failure: .red
        case .neutral: .secondary
        }
    }
}

private struct FleetManagerSummaryView: View {
    let summary: FleetRosterDisplay.Summary

    var body: some View {
        HStack(spacing: 20) {
            stat(summary.agents, "agents", .primary)
            stat(summary.subAgents, "sub-agents", .primary)
            stat(summary.running, "running", .blue)
            stat(summary.waiting, "waiting on you", summary.waiting > 0 ? .orange : .primary)
            stat(summary.failed, "failed", summary.failed > 0 ? .red : .primary)
            Spacer()
            Text(FleetRosterDisplay.workspaceLine(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func stat(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FleetManagerSectionView: View {
    let section: FleetRosterSection
    let sections: [FleetRosterSection]
    @ObservedObject var actions: FleetManagerActions
    @Binding var collapsed: Set<FleetRosterDisplay.Occurrence>
    let now: Date

    var body: some View {
        let counts = FleetRosterDisplay.sectionCounts(section)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(section.workspaceName).font(.headline)
                Text("window \(section.windowID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(FleetRosterDisplay.parkedLabel(section.isParked))
                    .font(.caption)
                    .foregroundStyle(section.isParked ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((section.isParked ? Color.secondary : Color.accentColor).opacity(0.12)))
                Spacer()
                HStack(spacing: 4) {
                    Text(counts.running)
                    Text("\u{00B7}")
                    Text(counts.waiting)
                        .foregroundStyle(section.waitingCount > 0 ? Color.orange : Color.secondary)
                        .fontWeight(section.waitingCount > 0 ? .semibold : .regular)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Delete", role: .destructive) {
                    actions.requestDeleteWorkspace(section: section)
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(actions.isDeletionInFlight)
                Button(section.isParked ? "Unpark" : "Park") {
                    if section.isParked {
                        actions.unpark(windowID: section.windowID)
                    } else {
                        actions.park(windowID: section.windowID)
                    }
                }
                .buttonStyle(CustomButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))
            Divider()
            if !section.isParked, let message = actions.parkMessage(for: section.windowID) {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                FleetManagerRowView(
                    row: row,
                    section: section,
                    sections: sections,
                    actions: actions,
                    collapsed: $collapsed,
                    now: now,
                    depth: 0
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct FleetManagerStateDot: View {
    let tone: FleetRosterDisplay.Tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var pulses: Bool {
        tone == .running && !reduceMotion
    }

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .opacity(pulses && dimmed ? 0.35 : 1)
            .onAppear { syncPulse() }
            .onChange(of: pulses) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        if pulses {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
        } else {
            withAnimation(.linear(duration: 0)) { dimmed = false }
        }
    }
}

private struct FleetManagerRollupBar: View {
    let line: FleetRosterDisplay.RollupLine
    private let width: CGFloat = 64

    var body: some View {
        let total = CGFloat(max(1, line.running + line.waiting + line.rest))
        HStack(spacing: 0) {
            Rectangle().fill(Color.blue).frame(width: width * CGFloat(line.running) / total)
            Rectangle().fill(Color.orange).frame(width: width * CGFloat(line.waiting) / total)
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: width * CGFloat(line.rest) / total)
        }
        .frame(width: width, height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct FleetManagerRowView: View {
    let row: FleetRosterRow
    let section: FleetRosterSection
    let sections: [FleetRosterSection]
    @ObservedObject var actions: FleetManagerActions
    @Binding var collapsed: Set<FleetRosterDisplay.Occurrence>
    let now: Date
    let depth: Int

    var body: some View {
        let tone = FleetRosterDisplay.tone(row.runState)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    FleetManagerStateDot(tone: tone)
                    Text(FleetRosterDisplay.stateLabel(row.runState))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tone.color)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(tone.color.opacity(0.12)))
                .frame(width: 140, alignment: .leading)
                nameCell
                if let kind = row.pendingKind {
                    Text(FleetRosterDisplay.pendingLabel(kind))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.14)))
                        .frame(width: 84, alignment: .leading)
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                }
                Text(FleetRosterDisplay.relativeTime(since: row.lastActivityAt, now: now))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                HStack(spacing: 6) {
                    Button("Show") {
                        Task {
                            await actions.show(
                                rowID: row.id,
                                windowID: section.windowID,
                                workspaceID: section.workspaceID,
                                sessionID: row.id
                            )
                        }
                    }
                    .buttonStyle(CustomButtonStyle(isPresetActive: tone == .waiting))
                    if actions.canArchive(rowID: row.id, windowID: section.windowID, workspaceID: section.workspaceID, sessionID: row.id) {
                        Button {
                            Task {
                                await actions.archive(rowID: row.id, windowID: section.windowID, workspaceID: section.workspaceID, sessionID: row.id)
                            }
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(CustomButtonStyle())
                        .hoverTooltip("Stash chat for later")
                        .accessibilityLabel("Archive")
                        .disabled(actions.isDeletionInFlight)
                    }
                    Button(role: .destructive) {
                        actions.requestDeleteChat(rowID: row.id, windowID: section.windowID, workspaceID: section.workspaceID, sessionID: row.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CustomButtonStyle())
                    .hoverTooltip("Delete chat")
                    .accessibilityLabel("Delete")
                    .disabled(actions.isDeletionInFlight)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if case let .otherWindow(windowID, sessionID, name)? = row.parent,
               let parentSection = sections.first(where: { $0.windowID == windowID })
            {
                HStack(spacing: 6) {
                    Text("Sub-agent of \(name) \u{00B7} window \(windowID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show parent") {
                        Task {
                            await actions.show(
                                rowID: row.id,
                                windowID: windowID,
                                workspaceID: parentSection.workspaceID,
                                sessionID: sessionID
                            )
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.leading, 12 + CGFloat(depth) * 18)
                .padding(.bottom, 6)
            }
            if let message = actions.staleMessage(for: row.id) {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            ForEach(FleetRosterDisplay.visibleChildren(of: row, in: section, collapsed: collapsed), id: \.id) { child in
                FleetManagerRowView(
                    row: child,
                    section: section,
                    sections: sections,
                    actions: actions,
                    collapsed: $collapsed,
                    now: now,
                    depth: depth + 1
                )
            }
        }
    }

    private var nameCell: some View {
        HStack(alignment: .top, spacing: 4) {
            if FleetRosterDisplay.hasDisclosure(row) {
                let occurrence = FleetRosterDisplay.occurrence(of: row, in: section)
                let isCollapsed = collapsed.contains(occurrence)
                Button {
                    if isCollapsed { collapsed.remove(occurrence) } else { collapsed.insert(occurrence) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand sub-agents" : "Collapse sub-agents")
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(row.agent) \u{00B7}")
                    Text(row.model).font(.caption.monospaced())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let line = FleetRosterDisplay.rollupLine(row.rollup) {
                    HStack(spacing: 6) {
                        Text(line.summary)
                        if let waiting = line.waitingText {
                            Text(waiting).foregroundStyle(.orange).fontWeight(.semibold)
                        }
                        if let other = line.otherWindowText {
                            Text(other)
                        }
                        FleetManagerRollupBar(line: line)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
