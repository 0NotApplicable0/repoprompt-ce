# Model Routing Architecture

Current as of 2026-09-19.

## Status

RepoPrompt CE contains a backend-neutral routing framework, generic Settings/composer integration, and a bundled Jev adapter. After a TypeSafe key is verified, Jev reports ready and Settings can enable one-shot routing. Agent Mode then exposes `Route once` for eligible fresh plain-text tasks.

## Authority boundary

The host framework owns:

- durable backend selection and role/provider consent;
- candidate construction from the effective Agent Models profile and live provider availability;
- complete executable target identity: provider, model, reasoning effort, and normalized ACP parameters;
- the privacy-bounded semantic request;
- exact request ownership, cancellation, normalized outcome validation, and eventual selection-and-submit transaction.

A backend adapter owns:

- backend identity and display metadata;
- credential/configuration readiness;
- wire encoding, transport, and strict response decoding;
- its versioned selection policy.

Adapters receive only exact task text plus opaque candidate keys and fixed role rubrics. They do not receive workspace/repository names, paths, file contents, selections, diffs, provider/model identifiers, transcripts, prompts, tools, permission state, downstream credentials, or provider session identity. They never invoke downstream providers.

`AgentTaskRouterRegistry` is an internal compile-time composition seam, not a dynamic plug-in ABI. Unknown persisted backend identifiers are preserved but resolve unavailable; the registry never substitutes another backend.

## Durable configuration

`scalarPreferences.modelRouter` is an optional schema-v9 group:

```text
enabled
selectedBackendRawValue
candidateRoleRawValues
allowedProviderRawValues
```

Absence resolves disabled. First enable must materialize the selected backend and explicit current role/provider sets. Later providers or roles do not become authorized automatically. Known-setting edits preserve unknown nonblank backend, role, and provider raw values for forward/rollback compatibility. Secrets never enter this document.

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

The composer captures backend-neutral one-shot routing intent in the immutable submit attempt. After the final destination and execution location are ready, but immediately before `submitUserTurn`, the host rechecks fresh/plain-text eligibility, builds two to four distinct executable targets from the active workspace's effective role settings and live availability, and awaits the selected registration through exact coordinator ownership. Selected targets are committed with provider, model, reasoning effort, and normalized ACP parameters. Any submission rejection rolls that complete target back without writing manual defaults. Abstention, failure, cancellation, and staleness block the send and retain the draft and explicit selection. Failed newly-created destinations are discarded and the exact source tab is reactivated.

An in-flight route is one ownership record indexed by both its source and final destination tabs. The visible destination exposes the exact cancel action, and either related tab rejects a second submit until that ownership settles. Cancellation removes both indexes before late backend completion can reach submission.

Jev's five-second deadline uses a first-result ownership bridge rather than structured task-group teardown: timeout or cancellation settles the caller immediately, cancels the transport task for cleanup, and filters any late result even if a transport ignores cancellation. Credential validation uses the same boundary, so generation cancellation cannot wait on or publish a late validation response.

`submitPreparedUserTurn`, `startAgentRun`, `AgentModeRunService`, MCP starts, continuations, steering, Chat/Oracle, and Context Builder remain unchanged.

## Jev selection policy

The current policy version binds the pinned `jev-1.13.0` evaluator to the v1 task contract and role rubrics. Jev receives two to four opaque criteria, and RepoPrompt accepts only a structurally valid response whose declared choice is the unique probability argmax. Authentication failure invalidates readiness for the credential generation that made the request. Transport, rate-limit, overload, timeout, and response-validation failures block submission and retain the user's draft and explicit target selection.

Quality evaluation can refine the instructions, rubrics, pinned evaluator, or acceptance rule in a later version. Such a change must advance the policy version and keep deterministic wire and response-validation fixtures. It is not a prerequisite for using the documented choice result.

## Validation scope

Repository tests cover schema-v9 preservation, workspace-aware candidate construction, provider filtering and executable-target deduplication, registration-owned Settings, readiness generation streams, transport cancellation, exact official Jev shapes, unique argmax/evaluator checks, authenticated backend routing, reservation-before-await coordinator ownership, prompt cancellation against non-cooperative backends, normalized optional evidence, and generic transaction placement. Live Jev quality and service availability require separate authorized-key validation; credentials and response bodies must never be committed or logged.
