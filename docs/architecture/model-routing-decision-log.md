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

Count `decision` events by chosen provider:

```bash
jq -s '[.[] | select(.event == "decision" and .chosenTarget != null)]
  | group_by(.chosenTarget.provider)
  | map({provider: .[0].chosenTarget.provider, count: length})' \
  "$HOME/Library/Application Support/RepoPrompt CE/Diagnostics/ModelRouter/jev-decisions.jsonl"
```
