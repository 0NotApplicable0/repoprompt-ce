# Model Routing Architecture

Current as of 2026-09-19.

## Status

RepoPrompt CE contains a backend-neutral routing framework, generic Settings/composer integration, and a bundled Jev adapter. The generic flow is exercised with deterministic fake-ready backends, but **Jev cannot route tasks yet**: there is no authorized live-key calibration corpus or reviewed acceptance policy in this repository. Jev therefore reports `policyUnavailable`, Settings cannot enable routing, and Agent Mode does not expose the one-shot routing control in production. This is intentional fail-closed behavior, not a fallback to the current model.

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
- its versioned, reviewed acceptance/abstention policy.

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

## Jev adapter

The bundled adapter uses TypeSafe's documented HTTP surface directly; there is no Swift SDK:

- `GET https://api.typesafe.ai/v1/models` validates an account from a supported Jev alias/family entry (`name`); the pinned version need not appear in that alias list;
- `POST https://api.typesafe.ai/v1/systemone` sends a map containing one `route` choice question and always pins evaluation to `jev-1.13.0`;
- Bearer authentication;
- one request, five-second outer deadline, no RepoPrompt-layer retry;
- explicit 401/403, 422, 429, and 529 classification;
- no request/response-body logging.

`JevRoutingResponseInterpreter` strictly validates returned evaluator identity, the single mapped `route` choice answer, exact opaque-key coverage, finite ranged probabilities, distribution sum, a unique probability argmax matching `choice`, confidence, and nonnegative usage. Confidence and winning probability remain distinct evidence. The interpreter intentionally does not choose acceptance thresholds.

The Jev key uses the dedicated `JevRouterAPIKey` secure-storage account. It is included in the complete repair inventory but excluded from provider/CLI, Claude-compatible, and frozen identity-migration inventories. The app-global credential service is shared across windows; each Settings window owns only its view model and observes live `APISettingsViewModel.agentAvailability`.

## Adding a bundled backend

1. Implement `AgentTaskRouterBackend` with a stable lowercase ID.
2. Keep transport, credentials, response validation, and acceptance policy in the backend directory.
3. Register the adapter once in `AgentTaskRouterRuntime`; duplicate IDs are programmer errors.
4. Attach its redacted Settings presentation/actions controller to the registration without putting secrets or backend switches into generic state.
5. Test unknown selection, cancellation, readiness-generation changes, privacy, and normalized outcomes using the generic coordinator.
6. Prove the backend can return `selected` only under a reviewed policy. Until then, return `policyUnavailable`.

Adding a backend must not require changes to candidate construction, the semantic privacy contract, or provider runtimes.

## Generic host integration

The composer captures backend-neutral one-shot routing intent in the immutable submit attempt. After the final destination and execution location are ready, but immediately before `submitUserTurn`, the host rechecks fresh/plain-text eligibility, builds two to four distinct executable targets from the active workspace's effective role settings and live availability, and awaits the selected registration through exact coordinator ownership. Selected targets are committed with provider, model, reasoning effort, and normalized ACP parameters. Any submission rejection rolls that complete target back without writing manual defaults. Abstention, failure, cancellation, and staleness block the send and retain the draft and explicit selection. Failed newly-created destinations are discarded and the exact source tab is reactivated.

`submitPreparedUserTurn`, `startAgentRun`, `AgentModeRunService`, MCP starts, continuations, steering, Chat/Oracle, and Context Builder remain unchanged.

## Remaining Jev activation work

Before Jev routing can become user-visible:

1. obtain an authorized key and a redacted calibration/held-out corpus;
2. freeze the pinned evaluator, semantic contract, rubric version, thresholds, and fixtures together;
3. demonstrate candidate-cardinality, ambiguity, multilingual/domain, adversarial, repeat-variance, and latency acceptance;
4. change Jev readiness from `policyUnavailable` to `ready` only when that reviewed policy is present and its policy version is bound to the pinned evaluator and fixtures;
5. validate with an authorized live key separately from deterministic repository fixtures, without committing credentials or response bodies.

## Validation scope

Repository tests cover schema-v9 preservation, workspace-aware candidate construction, provider filtering and executable-target deduplication, registration-owned Settings, readiness generation streams, transport cancellation, exact official Jev shapes, unique argmax/evaluator checks, reservation-before-await coordinator ownership, prompt cancellation against non-cooperative backends, normalized optional evidence, and generic transaction placement. Live Jev policy quality is deliberately **not** claimed or tested because no authorized key/corpus or acceptance threshold exists.
