import Foundation
import MCP

/// Canonical schema for the agent-only `session_admin` tool.
///
/// Kept beside, not inside, the encoded catalog in `MCPDomainCanonicalToolDefinitions` so the
/// delegation surface can grow per lane without re-encoding every other tool. The tool is
/// policy-gated (`agentSessionAdmin`): it is canonical in every catalog but advertised only to an
/// exact Agent Mode run holding a live delegation scope (or, for `request_scope`, to an
/// orchestrator/overseer run), and never to administrative principals.
package enum MCPDomainSessionAdminToolDefinition {
    /// Shared operation identities. Only the end-to-end implemented subset is advertised.
    package static let operations: [String] = [
        "request_scope", "scope_status", "release_scope", "attenuate",
        "inventory", "get", "tree", "links",
        "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups", "archive", "unarchive",
        "link", "unlink", "reparent", "adopt", "release", "retire",
        "fork", "set_model", "set_effort",
        "worktree_create", "worktree_bind", "worktree_unbind", "worktree_release", "worktree_inventory",
        "merge_preview", "merge_apply",
        "confirmation_status", "undo"
    ]

    /// Operations implemented end to end: the scope lifecycle (Lane A), the organizing ops (Lane B:
    /// inventory, organize, release, batch confirmation, undo), and the structure, lifecycle, and
    /// worktree-on-behalf ops (Lane C).
    package static let implementedOperations: Set<String> = [
        "request_scope", "scope_status", "release_scope", "attenuate",
        "inventory", "get", "tree", "links",
        "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups", "archive", "unarchive",
        "link", "unlink", "reparent", "adopt", "release", "retire",
        "fork", "set_model", "set_effort",
        "worktree_create", "worktree_bind", "worktree_unbind", "worktree_release", "worktree_inventory",
        "merge_preview", "merge_apply",
        "confirmation_status", "undo"
    ]

    /// Preserve the shared operation identities for later lanes, but never advertise reserved ops.
    package static let advertisedOperations: [String] = operations.filter { implementedOperations.contains($0) }

    package static let capabilityValues: [String] = DomainDelegationScopeCapability.allCases.map(\.rawValue)

    /// Shared static playbook; runtime receipts additionally identify the current setting.
    package static let overseerPlaybook = "Overseer full access ON: skips only ordinary request_scope/cards. direct_children needs explicit consent or a sufficient live matching grant; full access and session-wide approval never settle it. OFF: use a covering grant or request_scope; standing consent may skip a card; else one appears and you get a decision notice. scope_status lists operations, capabilities, grants on independently authorized routes."

    package static let definition = MCPDomainToolDefinition(
        name: MCPWindowToolName.sessionAdmin,
        description: """
        Administer Agent sessions inside a delegation scope the user granted to this session. Agent sessions only.

        A scope is user-approved authority over a set of sessions: `session` (the grantee and one exact `session_id`, never descendants), `tree` (this session's owned subtree), `direct_children` (immutable direct spawns still organizationally under this requester in its installed workspace), `workspace`, or `all_sessions`. Capabilities: observe, organize, control, restructure, spawn, worktree; `destructive` is a reserved flag no op requires. Ordinary `all_sessions` scopes hold only observe, organize, and restructure; the user's full-access setting supplies an unrestricted grant with every capability. Membership comes from RepoPrompt's own provenance, never from arguments; naming a session grants nothing.

        \(overseerPlaybook)

        `request_scope kind=direct_children` grants consent for explicit managed link activation; it creates no links automatically. Supported requester: a non-explore, parentless MCP-created controller on an exact current durable run route, with no creator-only lane provenance. Root and workspace come from that route; session_id/workspace replacements are rejected. Existing and future direct spawns only: no siblings, grandchildren, adopted workers, creator-only lanes, native-host subagents or cross-workspace children. Only observe, control and restructure are permitted, even with full access; default all three for 3600 seconds. Only expiry and bulk_confirmation_threshold guardrails apply; depth/session/worktree quotas are rejected. No attenuation. Before consent this route supports only that request and scope_status/release_scope with its own request_id, not inventory or management. A sufficient live grant permits scope_status/release_scope for its own scope_id and scoped management, including explicit link activation; every action rechecks current membership and exact endpoints. The user can narrow capabilities/expiry; reasons are unverified. Revoking the grant ends derived Overseer links and their managed actions; existing parent-session controls and already-started work are separate.

        For cleanup/organizing without covering authority, request `observe` together with mutation capabilities, then use `inventory`. A `workspace` scope covers only that workspace; cross-workspace `history` results are not scope membership.

        **Scope ops**
        - `request_scope`: request missing authority with exact capabilities. Returns `granted` with the actual covering `scope`/`scope_id` under applicable standing consent or full access (never substitutes for direct_children consent); otherwise `pending_user_approval` with a `request_id`. Nothing is granted while pending; wait for the app-authored decision notice or inspect `scope_status` with that request_id, not a duplicate request.
        - `scope_status`: when you need to inspect authority, call without selectors, for an operation catalog (tools, ops, required capabilities) alongside your current grants. Or inspect one `scope_id`/`request_id` (pending, granted, denied, revoked, expired). For a one-target request, `become_overseer` with `session_id` and optional `message` requests one exact-target approval and automatically prepares, links and dispatches; it does not require a filler user turn or a mid-turn catalog refresh.
        - `release_scope`: give up one of your scopes with `scope_id` (revokes its nested scopes too), or cancel your own pending request with `request_id`. Selectors are exclusive. A granted request requires releasing its actual scope; canceling a request grants no authority.
        - `confirmation_status`: read one of your batch cards by `confirmation_id`.

        **Inventory** (observe; scope members only): `inventory` (filter, limit; history-backed and may be incomplete), `get` (session_id), `tree` (session_id? root), `links` (session_id?). `total_complete` describes the selected records/filter; `history_complete` describes the selected history coverage. Global endpoint/link/orphan coverage is separate. An incomplete zero never proves an empty workspace. Organization fields are omitted when `organization_complete` is false and unknown fields never match pin/group/archive filters.
        **Organize** (organize): `rename` (name), `set_pin` (pinned), `reorder_pins` (order + expected_order CAS), `set_group` (group; empty string ungroups), `reorder_groups` (workspace, order + expected_order CAS), `archive`, `unarchive`. Reversible calls return an `undo_token` for `undo`. Only sessions in a workspace an open window shows can be changed; others report `workspace_not_loaded`.
        **Release** (restructure): `release` unlinks links among scope members and clears their Auto-wake; `retire` also stops (control) and archives.
        Target ops take `session_id`, `targets`, or `filter`; `preview: true` lists exact items and effects.

        **Structure ops** (members only; membership never grows by moving sessions)
        - `link`: oversight link from you to each member target (`observer_must_be_caller` for any other observer). `link` needs restructure; new links additionally need observe + control. Existing links are never upgraded. Omit scope_id when exactly one active scope holds the needed capabilities. `unlink`: from `observer_session_id` (default you), both in scope.
        - `reparent`: move targets under member `parent_session_id`. `adopt`: bring outside sessions and their subtrees under a member (user card; user-granted scopes only; never another scope's overseer). Refused with `placement_affects_other_scopes` if another scope's membership would change, `placement_unresolved` if a chain runs through an unloaded workspace.
        - `attenuate`: give member `session_id` a nested scope with `capabilities`/`guardrails` no wider than yours.
        - `set_model` (`model_id`), `set_effort` (`effort`): idle targets, needs control. `fork`: one target, needs spawn and `idempotency_key`; the fork joins your scope.
        - `worktree_create` (`repo_root`, `branch`, `base_ref`, `bind`), `worktree_bind` (`worktree`, `apply`: now|next_boundary), `worktree_unbind`, `worktree_release` (card; unbind + mark stale), `worktree_inventory` (`idle_days`), `merge_preview` (`merge_target`), `merge_apply` (`operation_id`; the user reviews it).

        **Rules**: Except under the user's unrestricted full-access grant, `retire` and bulk ops over the scope threshold (default 25) return `pending_confirmation` for one user card. When the user approves, the call is applied to the ticked items; read `applied_result` with `confirmation_status`. A repeat must be unchanged (same op, arguments, and `idempotency_key`, plus `confirmation_id`); changed arguments need a new card, and `confirmation_mismatch` lists the approved items. `retire` needs organize + restructure; running targets also need control and are otherwise listed as `requires_control`, never stopped. Recoverable denials: `scope_capability_missing`, `scope_guardrail_exceeded`, `scope_expired`, `confirmation_required`. Deleting sessions, removing worktrees, keys, permission modes, settings, and app control are human-only. Mutating calls take `idempotency_key`, except `undo`, which accepts only `op` and `undo_token` (no `scope_id`, `idempotency_key`, or `preview`).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "op": .object([
                    "type": .string("string"),
                    "enum": .array(advertisedOperations.map(Value.string)),
                    "description": .string("Required operation.")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("session"), .string("tree"), .string("direct_children"), .string("workspace"), .string("all_sessions")]),
                    "description": .string("[request_scope] Scope kind; session needs the exact session_id. direct_children requires a parentless MCP controller's exact route, forbids selectors, defaults to observe + control + restructure for 3600 seconds, and requires explicit consent. Default tree is rooted at this session.")
                ]),
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string("[request_scope] Workspace UUID for kind=workspace; default and limited to this session's workspace. Forbidden for direct_children, whose workspace is server-derived. [reorder_groups] Workspace UUID.")
                ]),
                "capabilities": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(capabilityValues.map(Value.string))
                    ]),
                    "description": .string("[request_scope, attenuate] Requested capabilities; the user may narrow them. Cleanup/organizing needs observe for inventory plus mutation capabilities (retire: organize and restructure). Nothing is added after approval.")
                ]),
                "guardrails": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "max_live_sessions": .object(["type": .string("integer"), "minimum": .int(0)]),
                        "max_depth": .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "description": .string(
                                "kind=tree only: spawn depth below this session. Rejected as guardrails_malformed for workspace or all_sessions."
                            )
                        ]),
                        "max_worktrees": .object(["type": .string("integer"), "minimum": .int(0)]),
                        "expires_in_seconds": .object(["type": .string("integer"), "minimum": .int(60)]),
                        "bulk_confirmation_threshold": .object(["type": .string("integer"), "minimum": .int(1)])
                    ]),
                    "description": .string("[request_scope, attenuate] Proposed guardrails; the user may tighten them. direct_children accepts only expires_in_seconds (default 3600) and bulk_confirmation_threshold, never depth/session/worktree quotas.")
                ]),
                "reason": .stringSchema("[request_scope] Unverified agent reason shown on the approval card, never authority. Max 500 UTF-8 bytes."),
                "scope_id": .stringSchema("[scope_status, release_scope, other ops except undo] Scope UUID; optional when you hold exactly one live scope. release_scope accepts either scope_id or request_id, never both."),
                "request_id": .stringSchema("[scope_status, release_scope] Your request UUID returned by request_scope. release_scope cancels only a pending request; use scope_id to release an already granted scope."),
                "session_id": .stringSchema("[target ops] One target session UUID."),
                "targets": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("[bulk ops] Target session UUIDs; exclusive with filter.")
                ]),
                "filter": .object([
                    "type": .string("object"),
                    "description": .string("[inventory, bulk ops] Keys: workspace, root_overseer, state, pinned, group (empty string or null = ungrouped), query, idle_days_gt, created_before, created_after, has_links, role (overseer|overseen), orphaned, archived, loaded. Exclusive with targets.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(500),
                    "description": .string("[inventory, tree, links] Max rows; default 100.")
                ]),
                "name": .stringSchema("[rename] New session name."),
                "pinned": .object([
                    "type": .string("boolean"),
                    "description": .string("[set_pin] true pins, false unpins.")
                ]),
                // Single-type schema: the app adapter's JSONSchema decoder rejects union `type` arrays,
                // so clearing is spelled as an empty string rather than `null`.
                "group": .stringSchema("[set_group] Sidebar group name (max 64 chars); an empty string removes the group."),
                "order": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("[reorder_pins] Desired order of pinned session UUIDs. [reorder_groups] Desired order of group names.")
                ]),
                "expected_order": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("[reorder_pins, reorder_groups] Current order of the same items (compare-and-swap).")
                ]),
                "undo_token": .stringSchema("[undo] Token returned by a reversible call. undo accepts only op and undo_token."),
                "preview": .object([
                    "type": .string("boolean"),
                    "description": .string("[mutating ops except undo] Dry run listing exact items and effects.")
                ]),
                "idempotency_key": .stringSchema("[request_scope, mutating ops except undo] New per request; reuse only for the same retry. Max 200 UTF-8 bytes."),
                "confirmation_id": .stringSchema("[confirmation_status, applying call] Confirmation UUID from pending_confirmation; its applied_result appears once the user approves. Pass it on an unchanged repeat of the carded call."),
                "observer_session_id": .stringSchema("[unlink] Observer session UUID; default you. [link] Only you."),
                "parent_session_id": .stringSchema("[reparent, adopt] Destination member session UUID; adopt defaults to you."),
                "model_id": .stringSchema("[set_model] Same-agent model_id from agent_manage.list_agents."),
                "effort": .stringSchema("[set_effort] Effort supported by the target's model."),
                "up_to_item_id": .stringSchema("[fork] Transcript row cutoff; default the latest row."),
                "repo_root": .stringSchema("[worktree_create, worktree_bind, merge_preview] Repository root in the target's workspace."),
                "branch": .stringSchema("[worktree_create] Branch to create or check out."),
                "base_ref": .stringSchema("[worktree_create] Base ref or commit."),
                "bind": .object(["type": .string("boolean"), "description": .string("[worktree_create] Also bind it to the target.")]),
                "apply": .object([
                    "type": .string("string"),
                    "enum": .array([.string("now"), .string("next_boundary")]),
                    "description": .string("[worktree_create, worktree_bind] now (default) or at the target's next idle boundary.")
                ]),
                "worktree": .stringSchema("[worktree_bind] Worktree selector: @id:<worktree_id>, path, branch, or name."),
                "worktree_id": .stringSchema("[worktree_unbind, worktree_release] Only this worktree; default all."),
                "merge_target": .stringSchema("[merge_preview] Merge target selector; default @main."),
                "operation_id": .stringSchema("[merge_apply] Operation ID from merge_preview."),
                "idle_days": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("[worktree_inventory] Flag worktrees idle longer than this.")])
            ]),
            "required": .array([.string("op")])
        ]),
        annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}

private extension Value {
    static func stringSchema(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }
}
