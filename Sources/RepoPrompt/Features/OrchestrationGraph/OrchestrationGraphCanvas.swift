import AppKit
import SwiftUI

/// Scroll-wheel zoom mapping. Trackpad pixel deltas used to jump ~20% per event.
enum OrchestrationGraphWorkspaceNodeMenu {
    enum Item: Equatable, Hashable, CaseIterable {
        case rename
        case delete
    }

    static func items(isSystemWorkspace: Bool) -> [Item] {
        isSystemWorkspace ? [.rename] : [.rename, .delete]
    }
}

enum GraphCanvasZoomMath {
    static let minZoom: CGFloat = 0.15
    static let maxZoom: CGFloat = 8

    static func scrollZoomFactor(verticalDelta: CGFloat, hasPreciseScrollingDeltas: Bool) -> CGFloat {
        let gain: CGFloat = hasPreciseScrollingDeltas ? 0.005 : 0.104
        let unbounded = exp(verticalDelta * gain)
        return min(max(unbounded, 0.944), 1.056)
    }
}

/// Force-directed node-link layout for the orchestration graph.
struct OrchestrationGraphCanvasLayout: Equatable {
    static let canvasPadding: CGFloat = 32
    static let workspaceHubRadius: CGFloat = 16
    /// Circle + label clearance so two workspace hubs never sit on top of each other.
    static let minWorkspaceHubSeparation: CGFloat = 180
    static let minNodePadding: CGFloat = 22
    static let minSessionToHubPadding: CGFloat = 44
    static let minForeignSessionToHubPadding: CGFloat = 88

    struct Node: Equatable, Identifiable {
        let id: OrchestrationGraphProjection.NodeID
        let title: String
        let center: CGPoint
        let radius: CGFloat
        let isWorkspace: Bool
        let runState: OrchestrationGraphProjection.SessionRunState?
        let isLive: Bool
        let collapsedCount: Int
        let target: OrchestrationGraphInspectorTarget?
        let clusterIndex: Int

        var isInProgress: Bool {
            switch runState {
            case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                true
            default:
                false
            }
        }

        func withCenter(_ center: CGPoint) -> Node {
            Node(
                id: id,
                title: title,
                center: center,
                radius: radius,
                isWorkspace: isWorkspace,
                runState: runState,
                isLive: isLive,
                collapsedCount: collapsedCount,
                target: target,
                clusterIndex: clusterIndex
            )
        }
    }

    struct Edge: Equatable {
        let source: OrchestrationGraphProjection.NodeID
        let target: OrchestrationGraphProjection.NodeID
        let kind: OrchestrationGraphProjection.EdgeKind
    }

    let nodes: [Node]
    let edges: [Edge]
    let size: CGSize

    static let empty = OrchestrationGraphCanvasLayout(
        nodes: [],
        edges: [],
        size: CGSize(width: 640, height: 480)
    )

    static func isHiddenPlaceholderCluster(_ cluster: OrchestrationGraphLayout.Cluster) -> Bool {
        cluster.sessionIDs.isEmpty && cluster.workspaceName == "Default"
    }

    static func visibleClusters(in layout: OrchestrationGraphLayout) -> [OrchestrationGraphLayout.Cluster] {
        layout.clusters.filter { !isHiddenPlaceholderCluster($0) }
    }

    static func make(
        snapshot: OrchestrationGraphSnapshot,
        containerWidth: CGFloat = 1100,
        containerHeight: CGFloat = 760,
        previous: OrchestrationGraphCanvasLayout? = nil
    ) -> OrchestrationGraphCanvasLayout {
        let projection = snapshot.projection
        let clusters = visibleClusters(in: snapshot.layout)
        guard !clusters.isEmpty else { return .empty }
        _ = (containerWidth, containerHeight, previous)

        var sessionByID: [UUID: OrchestrationGraphProjection.SessionNode] = [:]
        for node in projection.nodes {
            if case let .session(session) = node {
                sessionByID[session.sessionID] = session
            }
        }

        var drafts: [SimNode] = []
        for (clusterIndex, cluster) in clusters.enumerated() {
            let hiddenCount = cluster.sessionIDs.count(where: { !snapshot.layout.isRevealed(sessionID: $0) })
            if let workspaceID = cluster.workspaceID {
                drafts.append(
                    SimNode(
                        id: .workspace(workspaceID),
                        title: cluster.workspaceName ?? "Workspace",
                        isWorkspace: true,
                        runState: nil,
                        isLive: false,
                        collapsedCount: hiddenCount,
                        target: .workspace(workspaceID: workspaceID),
                        radius: workspaceHubRadius,
                        clusterIndex: clusterIndex
                    )
                )
            }
            for sessionID in cluster.sessionIDs where snapshot.layout.isRevealed(sessionID: sessionID) {
                let session = sessionByID[sessionID]
                let live = session?.status.isLive ?? false
                let runState = session?.status.runState
                let radius: CGFloat = switch runState {
                case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    live ? 11 : 9
                default:
                    6
                }
                drafts.append(
                    SimNode(
                        id: .session(sessionID),
                        title: snapshot.sessionName(for: sessionID),
                        isWorkspace: false,
                        runState: runState,
                        isLive: live,
                        collapsedCount: 0,
                        target: snapshot.target(forSessionID: sessionID)
                            ?? cluster.workspaceID.map { .workspace(workspaceID: $0) },
                        radius: radius,
                        clusterIndex: clusterIndex
                    )
                )
            }
        }

        let visible = Set(drafts.map(\.id))
        let links = projection.edges.compactMap { edge -> Edge? in
            guard visible.contains(edge.source), visible.contains(edge.target) else { return nil }
            return Edge(source: edge.source, target: edge.target, kind: edge.kind)
        }

        Self.placeRadially(nodes: &drafts, edges: links)
        var nodes = drafts.map {
            Node(
                id: $0.id,
                title: $0.title,
                center: CGPoint(x: $0.x, y: $0.y),
                radius: $0.radius,
                isWorkspace: $0.isWorkspace,
                runState: $0.runState,
                isLive: $0.isLive,
                collapsedCount: $0.collapsedCount,
                target: $0.target,
                clusterIndex: $0.clusterIndex
            )
        }
        Self.resolveOverlaps(&nodes)
        return Self.packed(nodes: nodes, edges: links)
    }

    static func minimumDistance(between a: Node, and b: Node) -> CGFloat {
        let body = a.radius + b.radius + minNodePadding
        if a.isWorkspace, b.isWorkspace {
            return max(body, minWorkspaceHubSeparation)
        }
        if a.isWorkspace || b.isWorkspace {
            let sameCluster = a.clusterIndex == b.clusterIndex
            return body + (sameCluster ? minSessionToHubPadding : minForeignSessionToHubPadding)
        }
        return body
    }

    private static func packed(nodes: [Node], edges: [Edge]) -> OrchestrationGraphCanvasLayout {
        let pad = canvasPadding + 24
        let minX = nodes.map(\.center.x).min() ?? 0
        let maxX = nodes.map(\.center.x).max() ?? 0
        let minY = nodes.map(\.center.y).min() ?? 0
        let maxY = nodes.map(\.center.y).max() ?? 0
        let shifted = nodes.map {
            $0.withCenter(CGPoint(x: $0.center.x - minX + pad, y: $0.center.y - minY + pad))
        }
        let width = max(maxX - minX + pad * 2, 240)
        let height = max(maxY - minY + pad * 2, 200)
        return OrchestrationGraphCanvasLayout(
            nodes: shifted,
            edges: edges,
            size: CGSize(width: width, height: height)
        )
    }

    private static func resolveOverlaps(_ nodes: inout [Node]) {
        guard nodes.count > 1 else { return }
        for _ in 0 ..< 48 {
            var moved = false
            for i in nodes.indices {
                for j in (i + 1) ..< nodes.count {
                    var dx = nodes[j].center.x - nodes[i].center.x
                    var dy = nodes[j].center.y - nodes[i].center.y
                    var dist = hypot(dx, dy)
                    if dist < 0.01 {
                        dx = 1
                        dy = 0
                        dist = 1
                    }
                    let needed = minimumDistance(between: nodes[i], and: nodes[j])
                    guard dist < needed else { continue }
                    let push = needed - dist
                    let ux = dx / dist
                    let uy = dy / dist
                    let weightI: CGFloat = nodes[i].isWorkspace ? 0 : 1
                    let weightJ: CGFloat = nodes[j].isWorkspace ? 0 : 1
                    let total = weightI + weightJ
                    guard total > 0 else { continue }
                    nodes[i] = nodes[i].withCenter(CGPoint(
                        x: nodes[i].center.x - ux * push * (weightJ / total),
                        y: nodes[i].center.y - uy * push * (weightJ / total)
                    ))
                    nodes[j] = nodes[j].withCenter(CGPoint(
                        x: nodes[j].center.x + ux * push * (weightI / total),
                        y: nodes[j].center.y + uy * push * (weightI / total)
                    ))
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    private static func nodeIDs(of layout: OrchestrationGraphCanvasLayout) -> Set<OrchestrationGraphProjection.NodeID> {
        Set(layout.nodes.map(\.id))
    }

    func node(id: OrchestrationGraphProjection.NodeID) -> Node? {
        nodes.first { $0.id == id }
    }

    /// Flow animation follows work into a live node. Completed/failed/idle targets stay still.
    func edgeCarriesProgress(_ edge: Edge) -> Bool {
        node(id: edge.target)?.isInProgress == true
    }

    private struct SimNode {
        let id: OrchestrationGraphProjection.NodeID
        let title: String
        let isWorkspace: Bool
        let runState: OrchestrationGraphProjection.SessionRunState?
        let isLive: Bool
        let collapsedCount: Int
        let target: OrchestrationGraphInspectorTarget?
        let radius: CGFloat
        let clusterIndex: Int
        var x: Double = 0
        var y: Double = 0
    }

    private static func placeRadially(nodes: inout [SimNode], edges: [Edge]) {
        let indexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        var children: [OrchestrationGraphProjection.NodeID: [OrchestrationGraphProjection.NodeID]] = [:]
        var hasParent: Set<OrchestrationGraphProjection.NodeID> = []
        for edge in edges {
            children[edge.source, default: []].append(edge.target)
            hasParent.insert(edge.target)
        }
        for key in children.keys {
            children[key]?.sort { lhs, rhs in
                guard let left = indexByID[lhs].map({ nodes[$0] }),
                      let right = indexByID[rhs].map({ nodes[$0] })
                else { return lhs.uuid.uuidString < rhs.uuid.uuidString }
                if left.title != right.title { return left.title < right.title }
                return left.id.uuid.uuidString < right.id.uuid.uuidString
            }
        }

        var hubIndices = nodes.indices.filter { nodes[$0].isWorkspace }
        hubIndices.sort { left, right in
            if nodes[left].title != nodes[right].title {
                return nodes[left].title < nodes[right].title
            }
            return nodes[left].id.uuid.uuidString < nodes[right].id.uuid.uuidString
        }

        let hubCount = hubIndices.count
        let hubRadius: Double = if hubCount <= 1 {
            0
        } else {
            max(
                Double(minWorkspaceHubSeparation) / (2 * sin(.pi / Double(hubCount))),
                120
            )
        }

        var placed: Set<OrchestrationGraphProjection.NodeID> = []
        for (hubOrder, hubIndex) in hubIndices.enumerated() {
            let angle = hubCount <= 1
                ? -Double.pi / 2
                : -Double.pi / 2 + Double(hubOrder) * 2 * .pi / Double(hubCount)
            nodes[hubIndex].x = cos(angle) * hubRadius
            nodes[hubIndex].y = sin(angle) * hubRadius
            placed.insert(nodes[hubIndex].id)
            let span = hubCount <= 1 ? 2 * .pi : (2 * .pi / Double(hubCount)) * 0.86
            placeFan(
                parentID: nodes[hubIndex].id,
                parentIndex: hubIndex,
                baseAngle: angle,
                span: span,
                depth: 1,
                nodes: &nodes,
                indexByID: indexByID,
                children: children,
                placed: &placed
            )
        }

        for index in nodes.indices where !placed.contains(nodes[index].id) {
            let hubIndex = hubIndices.first { nodes[$0].clusterIndex == nodes[index].clusterIndex }
                ?? hubIndices.first
            guard let hubIndex else { continue }
            let angle = atan2(nodes[hubIndex].y, nodes[hubIndex].x)
            let fallback = angle.isFinite ? angle : -Double.pi / 2
            nodes[index].x = nodes[hubIndex].x + cos(fallback) * 108
            nodes[index].y = nodes[hubIndex].y + sin(fallback) * 108
            placed.insert(nodes[index].id)
        }
    }

    private static func placeFan(
        parentID: OrchestrationGraphProjection.NodeID,
        parentIndex: Int,
        baseAngle: Double,
        span: Double,
        depth: Int,
        nodes: inout [SimNode],
        indexByID: [OrchestrationGraphProjection.NodeID: Int],
        children: [OrchestrationGraphProjection.NodeID: [OrchestrationGraphProjection.NodeID]],
        placed: inout Set<OrchestrationGraphProjection.NodeID>
    ) {
        let kids = (children[parentID] ?? []).filter { !placed.contains($0) && indexByID[$0] != nil }
        guard !kids.isEmpty else { return }
        let count = Double(kids.count)
        let arcNeeded = count * 76
        let step = max(108.0 + Double(depth) * 6, arcNeeded / max(span, 0.35))
        for (offset, childID) in kids.enumerated() {
            guard let childIndex = indexByID[childID] else { continue }
            let t = count == 1 ? 0.0 : (Double(offset) + 0.5) / count - 0.5
            let angle = baseAngle + t * span
            nodes[childIndex].x = nodes[parentIndex].x + cos(angle) * step
            nodes[childIndex].y = nodes[parentIndex].y + sin(angle) * step
            placed.insert(childID)
            let childSpan = count == 1 ? span * 0.72 : span / count * 1.55
            placeFan(
                parentID: childID,
                parentIndex: childIndex,
                baseAngle: angle,
                span: min(max(childSpan, 0.35), 2.4),
                depth: depth + 1,
                nodes: &nodes,
                indexByID: indexByID,
                children: children,
                placed: &placed
            )
        }
    }
}

/// Obsidian-style dark knowledge graph: circular nodes, labeled, linked by membership and dispatch.
struct OrchestrationGraphCanvas: View {
    let snapshot: OrchestrationGraphSnapshot
    var selectedWorkspaceID: UUID?
    var selectedSessionID: UUID?
    var clicksEnabled: Bool = true
    var showsEventCatcher: Bool = true
    let onSelect: (OrchestrationGraphInspectorTarget) -> Void
    var isSystemWorkspace: (UUID) -> Bool = { _ in false }
    var onRenameWorkspace: (UUID) -> Void = { _ in }
    var onDeleteWorkspace: (UUID) -> Void = { _ in }
    var onZoomChange: (CGFloat) -> Void = { _ in }

    @State private var layout = OrchestrationGraphCanvasLayout.empty
    @State private var pan = CGSize.zero
    @State private var zoom: CGFloat = 1
    @GestureState private var dragDelta = CGSize.zero

    private let canvasBackground = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let edgeMembership = Color(red: 0.45, green: 0.38, blue: 0.72).opacity(0.28)
    private let edgeDispatch = Color(red: 0.62, green: 0.52, blue: 0.95).opacity(0.55)

    var body: some View {
        GeometryReader { geo in
            let displayZoom = min(max(zoom, 0.15), 8)
            let displayPan = CGSize(
                width: pan.width + dragDelta.width,
                height: pan.height + dragDelta.height
            )
            ZStack {
                canvasBackground
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 30.0,
                        paused: !layout.nodes.contains(where: \.isInProgress)
                    )
                ) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        context.translateBy(x: size.width / 2 + displayPan.width, y: size.height / 2 + displayPan.height)
                        context.scaleBy(x: displayZoom, y: displayZoom)
                        context.translateBy(x: -layout.size.width / 2, y: -layout.size.height / 2)
                        drawGraph(in: &context, phase: phase)
                    }
                    .allowsHitTesting(false)
                }
                ForEach(layout.nodes) { node in
                    nodeHitTarget(
                        node,
                        at: worldToView(
                            node.center,
                            viewport: geo.size,
                            displayZoom: displayZoom,
                            displayPan: displayPan
                        ),
                        displayZoom: displayZoom
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                if showsEventCatcher {
                    GraphCanvasEventCatcher(
                        zoom: $zoom,
                        pan: $pan,
                        layoutSize: layout.size,
                        viewport: geo.size
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding(12)
            }
            .onAppear {
                rebuildLayout()
                fit(layout, in: geo.size)
            }
            .onChange(of: zoom) { _, newZoom in
                onZoomChange(newZoom)
            }
            .onChange(of: snapshot) { _, newSnapshot in
                layout = OrchestrationGraphCanvasLayout.make(
                    snapshot: newSnapshot,
                    containerWidth: max(geo.size.width, 720),
                    containerHeight: max(geo.size.height, 520),
                    previous: layout
                )
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            zoomButton(title: "−") {
                zoom = min(max(zoom / 1.25, GraphCanvasZoomMath.minZoom), GraphCanvasZoomMath.maxZoom)
            }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(minWidth: 40)
            zoomButton(title: "+") {
                zoom = min(max(zoom * 1.25, GraphCanvasZoomMath.minZoom), GraphCanvasZoomMath.maxZoom)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func zoomButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private func rebuildLayout() {
        layout = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
    }

    private func worldToView(
        _ world: CGPoint,
        viewport: CGSize,
        displayZoom: CGFloat,
        displayPan: CGSize
    ) -> CGPoint {
        CGPoint(
            x: (world.x - layout.size.width / 2) * displayZoom + viewport.width / 2 + displayPan.width,
            y: (world.y - layout.size.height / 2) * displayZoom + viewport.height / 2 + displayPan.height
        )
    }

    private func nodeHitTarget(
        _ node: OrchestrationGraphCanvasLayout.Node,
        at point: CGPoint,
        displayZoom: CGFloat
    ) -> some View {
        let size = max((node.radius * 2 + 28) * displayZoom, 44)
        return Button {
            if clicksEnabled, let target = node.target {
                onSelect(target)
            }
        } label: {
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!clicksEnabled || node.target == nil)
        .contextMenu {
            if case let .workspace(workspaceID) = node.id {
                ForEach(OrchestrationGraphWorkspaceNodeMenu.items(
                    isSystemWorkspace: isSystemWorkspace(workspaceID)
                ), id: \.self) { item in
                    switch item {
                    case .rename:
                        Button("Edit Name…") { onRenameWorkspace(workspaceID) }
                    case .delete:
                        Button("Delete…", role: .destructive) { onDeleteWorkspace(workspaceID) }
                    }
                }
            }
        }
        .accessibilityLabel(node.title)
        .position(point)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private func fit(_ canvas: OrchestrationGraphCanvasLayout, in viewport: CGSize) {
        guard canvas.size.width > 0, canvas.size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let scale = min(viewport.width / canvas.size.width, viewport.height / canvas.size.height)
        zoom = min(max(scale * 0.92, GraphCanvasZoomMath.minZoom), 1.45)
        pan = .zero
    }

    private func drawGraph(in context: inout GraphicsContext, phase: TimeInterval) {
        drawEdges(layout, in: &context, phase: phase)
        for node in layout.nodes {
            drawNode(node, in: &context, phase: phase)
        }
    }

    private func drawNode(
        _ node: OrchestrationGraphCanvasLayout.Node,
        in context: inout GraphicsContext,
        phase: TimeInterval
    ) {
        let selected = isSelected(node)
        let fillColor = fill(for: node)
        let pulse = node.isInProgress ? 0.5 + 0.5 * sin(phase * 3.4) : 0
        let workspaceActive = node.isWorkspace && layout.edges.contains {
            $0.kind == .membership && $0.source == node.id && layout.node(id: $0.target)?.isInProgress == true
        }
        let glowPad = 4 + (node.isInProgress ? 3 + 5 * pulse : (workspaceActive ? 3 + 2 * (0.5 + 0.5 * sin(phase * 2.2)) : 1))
        if node.isLive || node.isWorkspace || node.isInProgress {
            let glow = Path(ellipseIn: CGRect(
                x: node.center.x - node.radius - glowPad,
                y: node.center.y - node.radius - glowPad,
                width: (node.radius + glowPad) * 2,
                height: (node.radius + glowPad) * 2
            ))
            context.fill(glow, with: .color(fillColor.opacity(0.16 + 0.18 * pulse)))
        }
        if node.isInProgress {
            let ringPad = node.radius + 4 + 3 * pulse
            let ring = Path(ellipseIn: CGRect(
                x: node.center.x - ringPad,
                y: node.center.y - ringPad,
                width: ringPad * 2,
                height: ringPad * 2
            ))
            context.stroke(
                ring,
                with: .color(fillColor.opacity(0.45 + 0.4 * pulse)),
                style: StrokeStyle(
                    lineWidth: 1.4,
                    lineCap: .round,
                    dash: [5, 6],
                    dashPhase: CGFloat(phase * 42)
                )
            )
        }
        let circle = Path(ellipseIn: CGRect(
            x: node.center.x - node.radius,
            y: node.center.y - node.radius,
            width: node.radius * 2,
            height: node.radius * 2
        ))
        context.fill(circle, with: .color(fillColor))
        context.stroke(
            circle,
            with: .color(selected ? Color.white : Color.white.opacity(0.18 + 0.25 * pulse)),
            lineWidth: selected ? 2 : 1
        )
        let text = Text(node.title)
            .font(.system(size: node.isWorkspace ? 11 : 9, weight: node.isWorkspace ? .semibold : .regular))
            .foregroundColor(Color.white.opacity(node.isWorkspace || node.isLive ? 0.92 : 0.62))
        context.draw(
            context.resolve(text),
            in: CGRect(x: node.center.x - 54, y: node.center.y + node.radius + 4, width: 108, height: 28)
        )
    }

    private func isSelected(_ node: OrchestrationGraphCanvasLayout.Node) -> Bool {
        switch node.id {
        case let .workspace(id):
            selectedWorkspaceID == id
        case let .session(id):
            selectedSessionID == id
        }
    }

    private func fill(for node: OrchestrationGraphCanvasLayout.Node) -> Color {
        if node.isWorkspace {
            return Color(red: 0.45, green: 0.36, blue: 0.92)
        }
        switch node.runState {
        case .running:
            return Color(red: 0.35, green: 0.82, blue: 0.52)
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return Color(red: 0.98, green: 0.82, blue: 0.28)
        case .failed:
            return Color(red: 0.92, green: 0.32, blue: 0.36)
        case .completed, .cancelled, .expired:
            return Color(red: 0.38, green: 0.32, blue: 0.58)
        case .idle, .unknown, .unspecified, .none:
            return node.isLive
                ? Color(red: 0.42, green: 0.78, blue: 0.58)
                : Color(red: 0.32, green: 0.28, blue: 0.48)
        }
    }

    private func drawEdges(
        _ canvas: OrchestrationGraphCanvasLayout,
        in context: inout GraphicsContext,
        phase: TimeInterval
    ) {
        for edge in canvas.edges {
            guard let from = canvas.node(id: edge.source), let to = canvas.node(id: edge.target) else { continue }
            var dx = to.center.x - from.center.x
            var dy = to.center.y - from.center.y
            let distance = hypot(dx, dy)
            guard distance > 1 else { continue }
            dx /= distance
            dy /= distance
            let start = CGPoint(x: from.center.x + dx * from.radius, y: from.center.y + dy * from.radius)
            let end = CGPoint(x: to.center.x - dx * to.radius, y: to.center.y - dy * to.radius)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let active = canvas.edgeCarriesProgress(edge)
            let color = edge.kind == .dispatch ? edgeDispatch : edgeMembership
            if active {
                context.stroke(
                    path,
                    with: .color(color.opacity(0.95)),
                    style: StrokeStyle(
                        lineWidth: edge.kind == .dispatch ? 2.0 : 1.6,
                        lineCap: .round,
                        dash: [7, 8],
                        dashPhase: CGFloat(-phase * (edge.kind == .dispatch ? 56 : 42))
                    )
                )
                let travel = CGFloat(phase * (edge.kind == .dispatch ? 0.85 : 0.55)).truncatingRemainder(dividingBy: 1)
                let dot = CGPoint(
                    x: start.x + (end.x - start.x) * travel,
                    y: start.y + (end.y - start.y) * travel
                )
                let radius: CGFloat = edge.kind == .dispatch ? 3.1 : 2.6
                context.fill(
                    Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(Color.white.opacity(0.9))
                )
            } else {
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: edge.kind == .dispatch ? 1.4 : 1.0, lineCap: .round)
                )
            }
        }
    }
}

/// AppKit pinch and scroll-wheel zoom. SwiftUI MagnificationGesture does not fire reliably on macOS.
private struct GraphCanvasEventCatcher: NSViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    var layoutSize: CGSize
    var viewport: CGSize
    var clicksEnabled: Bool = true
    var onClick: ((CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            zoom: $zoom,
            pan: $pan,
            layoutSize: layoutSize,
            viewport: viewport,
            clicksEnabled: clicksEnabled,
            onClick: onClick
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.layoutSize = layoutSize
        context.coordinator.viewport = viewport
        context.coordinator.hostView = nsView
        context.coordinator.onClick = onClick
        context.coordinator.clicksEnabled = clicksEnabled
    }

    final class Coordinator {
        var zoom: Binding<CGFloat>
        var pan: Binding<CGSize>
        var layoutSize: CGSize
        var viewport: CGSize
        var onClick: ((CGPoint) -> Void)?
        var clicksEnabled: Bool
        weak var hostView: NSView?
        private var monitor: Any?
        private var mouseDownPoint: CGPoint?

        init(
            zoom: Binding<CGFloat>,
            pan: Binding<CGSize>,
            layoutSize: CGSize,
            viewport: CGSize,
            clicksEnabled: Bool,
            onClick: ((CGPoint) -> Void)?
        ) {
            self.zoom = zoom
            self.pan = pan
            self.layoutSize = layoutSize
            self.viewport = viewport
            self.clicksEnabled = clicksEnabled
            self.onClick = onClick
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, contains(event) else { return event }
                switch event.type {
                case .magnify:
                    applyZoom(factor: 1 + event.magnification, anchor: location(in: event))
                    return nil
                case .scrollWheel:
                    let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 4
                    let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 4
                    guard abs(vertical) >= abs(horizontal), abs(vertical) > 0.05 else { return event }
                    applyZoom(
                        factor: GraphCanvasZoomMath.scrollZoomFactor(
                            verticalDelta: vertical,
                            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
                        ),
                        anchor: location(in: event)
                    )
                    return nil
                case .leftMouseDown:
                    mouseDownPoint = location(in: event)
                    return event
                case .leftMouseUp:
                    let up = location(in: event)
                    if clicksEnabled, let down = mouseDownPoint,
                       hypot(up.x - down.x, up.y - down.y) < 6
                    {
                        onClick?(up)
                    }
                    mouseDownPoint = nil
                    return event
                default:
                    return event
                }
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let hostView, let window = hostView.window, event.window === window else { return false }
            let point = hostView.convert(event.locationInWindow, from: nil)
            return hostView.bounds.contains(point)
        }

        private func location(in event: NSEvent) -> CGPoint {
            guard let hostView else { return .zero }
            return hostView.convert(event.locationInWindow, from: nil)
        }

        private func applyZoom(factor: CGFloat, anchor: CGPoint) {
            let oldZoom = zoom.wrappedValue
            let newZoom = min(max(oldZoom * factor, GraphCanvasZoomMath.minZoom), GraphCanvasZoomMath.maxZoom)
            guard abs(newZoom - oldZoom) > 0.0001, oldZoom > 0 else { return }
            let worldX = (anchor.x - viewport.width / 2 - pan.wrappedValue.width) / oldZoom + layoutSize.width / 2
            let worldY = (anchor.y - viewport.height / 2 - pan.wrappedValue.height) / oldZoom + layoutSize.height / 2
            zoom.wrappedValue = newZoom
            pan.wrappedValue = CGSize(
                width: anchor.x - viewport.width / 2 - (worldX - layoutSize.width / 2) * newZoom,
                height: anchor.y - viewport.height / 2 - (worldY - layoutSize.height / 2) * newZoom
            )
        }
    }
}
