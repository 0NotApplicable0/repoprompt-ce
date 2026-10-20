# Model Routing Decision Log

RepoPrompt CE appends JSON Lines records for routed task starts and Auto Effort judgments to a local diagnostics file:

```text
~/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl
```

When the active file would exceed `5 MiB` (`5_242_880` bytes), the logger rotates `jev-decisions.jsonl` to `jev-decisions.jsonl.1` (replacing any prior `.1` file) before writing the new line. At most two files exist on disk.

The log is enabled by default. It never records task text, prompt excerpts, file paths, or API keys.

## Event Kinds

Every line is a single JSON object with `"schema": 1`, an ISO-8601 `"timestamp"`, and an `"event"` discriminator (`"decision"` or `"applied"`). All events emitted for a single routed turn share the same `"requestID"`.

### `decision`

Written once per `(requestID, stage)` for:

- `stage = "model"` — global model router stage-1 model pick (`outcome` in `selected`, `abstained`, `failed`, `cancelled`, `localSingleCandidate`).
- `stage = "effort"` — global model router stage-2 effort pick (`outcome` in `selected`, `abstained`, `failed`, `cancelled`, `localSingleCandidate`).
- `stage = "autoEffort"` — Auto Effort judgment (`outcome` in `selected`, `abstained`, `failed`, `cancelled`).

Fields:

| Field | Type | Notes |
| --- | --- | --- |
| `schema` | `Int` | Currently `1`. |
| `event` | `String` | `"decision"`. |
| `timestamp` | `String` | ISO-8601 UTC timestamp with fractional seconds. |
| `requestID` | `String` | UUID shared across stages and the terminal `applied` event for a route. |
| `sessionID` | `String?` | Session UUID when known at decision time, otherwise `null`. |
| `scope` | `String` | `"primarySession"`, `"subagent"`, or `"headless"`. |
| `stage` | `String` | `"model"`, `"effort"`, or `"autoEffort"`. |
| `outcome` | `String` | `"selected"`, `"abstained"`, `"failed"`, `"cancelled"`, or `"localSingleCandidate"`. |
| `backend` | `String?` | `"jev"`, `"openai-decisions"`, `"local"`, or `null`. |
| `jevModel` | `String?` | Decision service model identifier when a remote backend answered, otherwise `null`. |
| `policyVersion` | `String?` | Acceptance policy version from the decision evidence when present. |
| `candidates` | `[Candidate]` | Full candidate list (each object has `key`, `provider`, `model`, `effort`, `modelParameters`). |
| `chosenKey` | `String?` | Decision service's original selected opaque key (`"c0"`, `"effort-1"`, etc.), or `null`; exploration does not rewrite it. |
| `chosenTarget` | `Target?` | Decision service's original selected provider/model/effort/parameters target, or `null`; exploration does not rewrite it. |
| `probabilities` | `[String: Double]?` | Per-candidate probabilities keyed by opaque key when decoded from the backend response (`null` otherwise; never invented). |
| `confidence` | `Double?` | Backend confidence when decoded (`null` otherwise; never invented). |
| `reasonCode` | `String?` | Backend abstention code, or `router_disabled` / `backend_not_ready` for a pre-route diversity fallback; otherwise `null`. |
| `inputTokens` | `Int?` | Decision request input tokens when reported, otherwise `null`. |
| `outputTokens` | `Int?` | Decision response output tokens when reported, otherwise `null`. |
| `latencyMs` | `Double?` | Monotonic service-call latency through readiness recheck, or `null` when no service call settled (including local picks and early cancellation). |
| `failure` | `String?` | Failure category raw value when `outcome == "failed"`, otherwise `null`. |
| `rationale` | `String?` | Always `null` (reserved; task/rationale prose is never persisted). |
| `makerExclusions` | `[String: [String]]?` | Model-stage map from excluded maker (`anthropic`, `openai`, `google`, `xai`, `cursor`) to sources in canonical order: `exclude_makers`, `diverse_from_sessions`, `review_diversity`. `null` without exclusions and on effort / Auto Effort rows. |

The `override` field is an object for every counted Jev model-stage selection (including Randomness Off), otherwise `null`. Old rows without this field remain decodable. It contains:

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `String` | `exploration`, `none`, or `explorationUnavailable`. |
| `randomness` | `String` | `off`, `low`, `medium`, or `high` captured for this decision. |
| `counter` | `UInt64` | One-based per-scope model-stage selection count. |
| `position` | `Int` | One-based position in the 20-decision cycle. |
| `originalKey` | `String` | Jev's original selected key, matching `chosenKey`. |
| `appliedKey` | `String` | Runner-up key when exploring; otherwise `originalKey`. |
| `durable` | `Bool` | Whether this count was persisted successfully. |

`explorationUnavailable` means the position called for exploration but no valid runner-up could be established from `DecisionEvidence.probabilities`. Missing probabilities are never inferred from scores. The original pick and probability evidence retain their Jev meaning; `appliedKey` records the post-exploration model before effort routing. An explored pick skips usage balancing. `none` and `explorationUnavailable` retain ordinary usage-balancing behavior, so `appliedKey` is not a final start target. The terminal `applied` event records the actual selection. Effort and Auto Effort rows always have `override: null`.

Maker exclusions filter the model candidates before the decision request. A single allowed model is applied locally; its effort stage proceeds normally. An empty allowed set emits a failed model event with `failure = "allCandidatesExcluded"` and rejects the start without a decision request. With exclusions, a disabled or unavailable router emits a failed model event before fallback. An excluded, unknown, or missing baseline rejects the start (`fallbackDiversityExcluded`); usage balancing cannot rescue that baseline or replace an allowed one with an excluded maker. These host policy failures do not add categories to the generic decision-service protocol. Old log rows without `makerExclusions` remain decodable.

### `applied`

Written once per routed composer submission, `agent_run` start, or `agent_explore` start after the session starts or the start is rejected. Joins to the route's `decision` events by `requestID`.

Fields:

| Field | Type | Notes |
| --- | --- | --- |
| `schema` | `Int` | Currently `1`. |
| `event` | `String` | `"applied"`. |
| `timestamp` | `String` | ISO-8601 UTC timestamp with fractional seconds. |
| `requestID` | `String` | Matches the route's `decision` events. |
| `sessionID` | `String?` | Started session UUID, or `null` when `outcome == "rejected"`. |
| `scope` | `String` | `"primarySession"`, `"subagent"`, or `"headless"`. |
| `outcome` | `String` | `"applied"` (router pick used), `"fallback"` (baseline/default used instead of router pick), `"rejected"` (start failed or was blocked), or `"notStarted"` (submission did not start an inactive session). |
| `provider`, `model`, `effort` | `String?` | Applied selection, or `null` when rejected/not started. An explicit effort encoded in a Claude/Codex model identifier is projected into `effort`. |
| `modelParameters` | `[Parameter]` | Applied provider parameter selections; empty when rejected/not started. |
| `picked` | `Target?` | Router-selected target before any fallback (`null` when no pick was made). |

## Upstream evidence mapping

`DecisionEvidence` supplies `policyVersion` (`acceptancePolicyVersion`), `confidence`, per-key `probabilities`, and usage counts. Missing evidence remains JSON `null`; scores are not converted into probabilities. `jevModel` retains the legacy field name and identifies the pinned evaluator only when evidence matches the backend's validated acceptance policy. Upstream adapters validate that model before exposing evidence. `latencyMs` is measured by `DecisionCoordinator`; it is not a backend-reported duration. Auto Effort uses the service's acceptance policy version, not the consumer's prompt-policy version. Rationale is always `null`.

## Inspecting with `jq`

Count `decision` events by chosen provider:

```bash
jq -r 'select(.event == "decision" and .chosenTarget.provider != null) | .chosenTarget.provider' \
  "$HOME/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl" \
  | sort | uniq -c | sort -nr
```

Join each `applied` event with its stage decisions by `requestID`:

```bash
jq -s 'group_by(.requestID) | map({
  requestID: .[0].requestID,
  decisions: map(select(.event == "decision") | {stage, outcome, chosenTarget}),
  applied: (map(select(.event == "applied")) | .[0] | {outcome, sessionID, provider, model, effort, modelParameters, picked})
})' "$HOME/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl"
```
