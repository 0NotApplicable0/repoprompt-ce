# Model Routing Architecture

Current as of 2026-09-19.

## Status

RepoPrompt CE contains a backend-neutral routing framework, app-global Settings and Agent Mode integration, and a bundled Jev adapter. After a TypeSafe key is verified, the persistent `Router` pill can enable routing across sessions. While enabled, routing applies to each new user-created Agent Mode session and each RepoPrompt-managed subagent start. Existing provider sessions, continuations, and steering retain their established target.

## Authority boundary

The host framework owns:

- durable enablement, backend selection, role/provider consent, per-scope provider limits, and custom guidance;
- candidate construction from the effective Agent Models profile and live provider availability;
- complete executable target identity: provider, model, reasoning effort, and normalized ACP parameters;
- the privacy-bounded semantic request;
- exact request ownership, cancellation, normalized outcome validation, and eventual selection-and-submit transaction.

A backend adapter owns:

- backend identity and display metadata;
- credential/configuration readiness;
- wire encoding, transport, and strict response decoding;
- its versioned selection policy.

Adapters receive the exact task text, optional user-authored routing guidance, routing scope, opaque candidate keys, candidate provider/model/effort descriptions, and fixed role rubrics. They do not receive workspace/repository names, paths, file contents, selections, diffs, transcripts, system prompts, tools, permission state, downstream credentials, or provider session identity. They never invoke downstream providers.

`AgentTaskRouterRegistry` is an internal compile-time composition seam, not a dynamic plug-in ABI. Unknown persisted backend identifiers are preserved but resolve unavailable; the registry never substitutes another backend.

## Durable configuration

`scalarPreferences.modelRouter` is an optional group introduced in schema v9 and extended in schema v10:

```text
enabled
selectedBackendRawValue
candidateRoleRawValues
allowedProviderRawValues
primaryProviderRawValue
subagentProviderRawValue
customInstructions
```

Absence resolves disabled. First enable must materialize the selected backend and explicit current role/provider sets. Later providers or roles do not become authorized automatically. The optional primary and subagent provider fields narrow each scope to one already-authorized provider. Custom guidance is trimmed, limited to 1,000 characters and 4,096 UTF-8 bytes, and sent to the routing backend with each request. Known-setting edits preserve unknown nonblank backend, role, and provider raw values for forward/rollback compatibility. Secrets never enter this document.

Nil role/provider arrays mean the policy has not yet been materialized and may use the first-enable preview. Explicit empty arrays mean no consent: they survive reload, render empty, and cannot build candidates or enable routing. Deselecting the final known role or provider therefore remains empty rather than reopening the default-all policy.

## Jev adapter

The bundled adapter uses TypeSafe's documented HTTP surface directly; there is no Swift SDK:

- `GET https://api.typesafe.ai/v1/models` validates an account from a supported Jev alias/family entry (`name`); the pinned version need not appear in that alias list;
- `POST https://api.typesafe.ai/v1/systemone` sends a map containing one `route` choice question and always pins evaluation to `jev-1.13.0`;
- Bearer authentication;
- one request, five-second outer deadline, no RepoPrompt-layer retry;
- explicit 401/403, 422, 429, and 529 classification;
- no request/response-body logging.

`JevRoutingResponseInterpreter` strictly validates returned evaluator identity, the single mapped `route` choice answer, exact opaque-key coverage, finite ranged probabilities, distribution sum, a unique probability argmax matching `choice`, confidence, and nonnegative usage. The v1 selection policy accepts that unique validated argmax and records the full probability distribution, confidence, and token usage as evidence. It does not apply a separate confidence threshold.

The Jev key uses the dedicated `JevRouterAPIKey` secure-storage account. It is included in the complete repair inventory but excluded from provider/CLI, Claude-compatible, and frozen identity-migration inventories. The app-global credential service is shared across windows; each Settings window owns only its view model and observes live `APISettingsViewModel.agentAvailability`.

Startup readiness observation is noninteractive and network-free. The runtime bootstraps stored credentials only for an explicitly selected, enabled backend; inactive and disabled backends are not contacted. Selecting a backend while routing remains disabled also does not validate it—validation is an explicit Settings action.

## Adding a bundled backend

1. Implement `AgentTaskRouterBackend` with a stable lowercase ID.
2. Keep transport, credentials, response validation, and acceptance policy in the backend directory.
3. Register the adapter once in `AgentTaskRouterRuntime`; duplicate IDs are programmer errors.
4. Attach its redacted Settings presentation/actions controller to the registration without putting secrets or backend switches into generic state.
5. Test unknown selection, cancellation, readiness-generation changes, privacy, and normalized outcomes using the generic coordinator.
6. Return `selected` only after validating the response against the submitted opaque candidate set and the backend's versioned policy.

Adding a backend must not require changes to candidate construction, the semantic privacy contract, or provider runtimes.

## Generic host integration

For a new user-created Agent Mode session, the host reads the persistent policy after the final destination and execution location are ready, but immediately before `submitUserTurn`. It rechecks fresh-session eligibility, builds one to four distinct executable targets from the active workspace's effective role settings and live availability, applies the primary-session provider limit, and awaits the selected registration through exact coordinator ownership. One remaining target is applied locally without a Jev request. Selected targets are committed with provider, model, reasoning effort, and normalized ACP parameters. Any submission rejection rolls that complete target back without writing manual defaults. Abstention, failure, cancellation, and staleness block the send and retain the draft and explicit selection. Failed newly-created destinations are discarded and the exact source tab is reactivated.

RepoPrompt-managed `agent_run` and `agent_explore` starts use the same policy with subagent scope and its provider limit. Routing occurs before the provider session starts. An explicit compound `model_id` or explicit `model_parameters` request remains authoritative and bypasses global routing. Role-based and default child starts may be routed. A settings revision/backend fence rejects a result when the global policy changes while Jev is deciding.

An in-flight route is one ownership record indexed by both its source and final destination tabs. The visible destination exposes the exact cancel action, and either related tab rejects a second submit until that ownership settles. Cancellation removes both indexes before late backend completion can reach submission.

Jev's five-second deadline uses a first-result ownership bridge rather than structured task-group teardown: timeout or cancellation settles the caller immediately, cancels the transport task for cleanup, and filters any late result even if a transport ignores cancellation. Credential validation uses the same boundary, so generation cancellation cannot wait on or publish a late validation response.

When Router is disabled, top-level submission and MCP child-start selection follow their previous paths without creating a routing request. Continuations, steering, Chat/Oracle, Context Builder, and provider-owned nested behavior remain unchanged in both states.

## Jev selection policy

The current policy version binds the pinned `jev-1.13.0` evaluator to the v2 session-routing contract, target descriptions, scope, optional custom guidance, and role rubrics. Jev receives two to four opaque criteria with human-readable provider/model/effort descriptions, and RepoPrompt accepts only a structurally valid response whose declared choice is the unique probability argmax. Authentication failure invalidates readiness for the credential generation that made the request. Transport, rate-limit, overload, timeout, and response-validation failures block the affected start; top-level failures retain the user's draft and explicit target selection.

Quality evaluation can refine the instructions, rubrics, pinned evaluator, or acceptance rule in a later version. Such a change must advance the policy version and keep deterministic wire and response-validation fixtures. It is not a prerequisite for using the documented choice result.

## Validation scope

Repository tests cover schema-v9 compatibility and schema-v10 scoped policy preservation, workspace-aware candidate construction, provider filtering and executable-target deduplication, one-target local application, registration-owned Settings, readiness generation streams, transport cancellation, exact official Jev shapes, scope/guidance encoding, unique argmax/evaluator checks, authenticated backend routing, reservation-before-await coordinator ownership, prompt cancellation against non-cooperative backends, normalized optional evidence, and primary/subagent transaction placement. Live Jev quality and service availability require separate authorized-key validation; credentials and response bodies must never be committed or logged.
