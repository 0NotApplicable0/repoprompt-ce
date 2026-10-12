# Model Router decision log

The Model Router keeps a local, default-on JSONL record of what it decided and what was then applied.
It is a diagnostic record: it never changes which target is chosen, never blocks a start, and has no
setting to disable it.

## Location and retention

```text
~/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl
~/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl.1
```

Each line is one JSON object with an `event` field. At most two files exist: the active file and one
rotated file (`.1`).

Rotation is a fixed size threshold (default 5 MiB, never below 64 KiB). Before a row is appended, the
active file is rotated when it is non-empty and the row would push it past the threshold: the old `.1` is
deleted, the active file becomes `.1`, and a fresh active file starts. A single row larger than the
threshold is still written whole, alone, to a fresh active file; the next row rotates it. Rows are never
truncated, split or intentionally dropped while the log is writable.

## Admission

Writes are serialized through one actor. A 1 MiB budget counts queued plus in-flight bytes and is
backpressure, not a cap: when the budget is full, callers wait in FIFO order, and a waiter's bytes are
reserved and queued before the waiter resumes, so a later small row cannot overtake an older large one.
A cancelled route still waits and its row is still written once.
A caller waits only until its decision row is admitted to the queue, which fixes its order, while the physical append and the route's applied row follow asynchronously.

If a physical open, append or rotate fails, only that row is discarded, a drop counter is incremented
and one `os_log` error is written. Routing and run start never fail, block or change because of the log.

## Privacy

Rows are built from an explicit allowlist. They never contain the task, the task excerpt, custom routing
instructions, rubrics, API keys or file system paths. `rationale` is always `null` because the decoded
Jev response contract exposes none. Candidates are the executable targets (provider, model, effort and
model parameters) with their opaque per-request keys.

## `decision` events

Written exactly once per `(requestID, stage)` for a Jev model-stage pick, a Jev effort-stage pick, an
Auto Effort judgment, an abstention, a failure, a cancellation, and a local single-candidate application
made without a Jev request.

| Field | Meaning |
| --- | --- |
| `event` | `"decision"` |
| `schema`, `timestamp` | Schema version (`1`) and ISO-8601 time. |
| `requestID` | The route's id; every `applied` row for the route carries the same id. |
| `sessionID` | Session id, `null` before a session is allocated. |
| `scope` | `primarySession`, `subagent` or `headless`. |
| `stage` | `model`, `effort` or `autoEffort`. |
| `outcome` | `selected`, `abstained`, `failed`, `cancelled` or `localSingleCandidate`. |
| `backend` | Router backend id (`jev`), or `local`. |
| `jevModel`, `policyVersion` | Pinned Jev model and policy version when Jev answered. |
| `candidates` | Every candidate: `key`, `provider`, `model`, `effort`, `modelParameters`. |
| `chosenKey`, `chosenTarget` | The chosen opaque key and its executable target. |
| `probabilities`, `confidence` | Jev's per-candidate probabilities and confidence. |
| `reasonCode` | Reason reported with the decision. |
| `inputTokens`, `outputTokens` | Jev usage. |
| `latencyMs` | Monotonic milliseconds around the backend call. |
| `failure` | Failure category when one exists. |
| `rationale` | Always `null`. |
| `makerExclusions` | Model stage only; `null` on `effort`, `autoEffort` and when nothing was excluded. Maps each excluded maker to the sources that excluded it, always in the order `exclude_makers`, `diverse_from_sessions`, `review_diversity`. `exclude_makers` is an explicit exclusion, `diverse_from_sessions` excludes makers by session diversity, and `review_diversity` is Review diversity. |
| `override` | Model stage only; always present. `null` unless Jev selected among at least two surviving models and the decision was counted, then an object (see below). `chosenKey`, `chosenTarget` and `probabilities` stay Jev's own choice; an `applied` row reports the final executable target. |

### `override` object

| Field | Meaning |
| --- | --- |
| `kind` | `none` (counted, not exploring), `exploration` (Jev's runner-up replaced the pick) or `explorationUnavailable` (exploring position, no valid runner-up, Jev's pick kept). |
| `randomness` | Raw level at the decision: `off`, `low`, `medium` or `high`. |
| `counter` | Unsigned 64-bit count issued for the routing scope: primary session or subagent (a `headless` subagent uses the subagent counter). |
| `position` | Cycle position, `1...20`. |
| `originalKey` | Jev's chosen key. |
| `appliedKey` | Key output by the exploration step; it is not the later usage-balancing or effort result. |
| `durable` | `true` when committed under the counter-file lock; `false` for a degraded in-memory value. |

The schema stays `1`; `override` is additive.

## `applied` events

Written exactly once per routed start or composer submission that produced a decision, after the run
reached its provider pipeline or the start was rejected. A router-off or explicitly pinned start writes
none.

| Field | Meaning |
| --- | --- |
| `event`, `schema`, `timestamp`, `requestID`, `scope` | As above, with `event` = `"applied"`. |
| `sessionID` | `null` when the start is rejected. |
| `outcome` | `applied` (the picked target ran), `fallback` (a different target replaced the pick), `rejected`, or `notStarted` (the message steered or queued into a live run). |
| `provider`, `model`, `effort`, `modelParameters` | The target that was actually applied. |
| `picked` | The target the router picked, or `null` when it picked none. |

"Applied" means the run reached its provider pipeline (or was rejected before it). A provider that fails
later is an ordinary run failure and is not reinterpreted here. Decision rows are always written before
the application row of the same route.

## Example

Count exploring model decisions by scope:

```bash
jq -s 'map(select(.event=="decision" and .stage=="model" and .override.kind=="exploration")) | group_by(.scope) | map({scope:.[0].scope,exploring:length})' jev-decisions.jsonl
```

Count `decision` events by chosen provider:

```bash
jq -s '[.[] | select(.event == "decision" and .chosenTarget != null)]
  | group_by(.chosenTarget.provider)
  | map({provider: .[0].chosenTarget.provider, count: length})' \
  "$HOME/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl"
```
