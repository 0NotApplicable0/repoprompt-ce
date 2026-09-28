#!/usr/bin/env bash
# Live CE CLI probe. Run only when the debug app is already running.
set -uo pipefail

warning='--new-window is deprecated; workspaces open on the existing window'
created_id=''
created_maybe=0

fail() {
    printf 'PROBE FAILED: %s\n' "$*" >&2
    exit 1
}

if [[ ${RPCE_DEBUG_CLI+x} ]]; then
    cli=$RPCE_DEBUG_CLI
    [[ -f "$cli" && -x "$cli" ]] || fail "RPCE_DEBUG_CLI is not an executable file: $cli"
else
    cli=''
    for candidate in \
        "$HOME/RepoPrompt/repoprompt_ce_cli_debug" \
        "$HOME/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"; do
        if [[ -f "$candidate" && -x "$candidate" ]]; then
            cli=$candidate
            break
        fi
    done
    if [[ -z "$cli" ]]; then
        cli=$(command -v rpce-cli-debug 2>/dev/null || true)
    fi
    [[ -f "$cli" && -x "$cli" ]] || fail 'debug CLI unavailable: set RPCE_DEBUG_CLI or install rpce-cli-debug'
fi
command -v python3 >/dev/null 2>&1 || fail 'python3 is required to inspect CLI responses'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/rpce-one-window-probe.XXXXXXXX") || fail 'cannot create temporary directory'

cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$created_maybe" == 1 ]]; then
        if [[ -n "$created_id" ]]; then
            if ! "$cli" -e "workspace delete $created_id" >"$tmp_dir/delete.out" 2>"$tmp_dir/delete.err"; then
                printf 'MANUAL CLEANUP: deletion of created workspace id %s failed.\n' "$created_id" >&2
                cat "$tmp_dir/delete.err" >&2
                result=1
            fi
        else
            printf 'MANUAL CLEANUP: create succeeded, but its exact UUID could not be verified. Inspect ow-probe; no deletion was attempted. Create response:\n' >&2
            cat "$tmp_dir/create.out" >&2
            result=1
        fi
    fi
    rm -rf -- "$tmp_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

window_count() {
    local output=$1
    python3 - "$output" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
counts = re.findall(r'(?m)^### Windows\r?\n- \*\*Count\*\*: ([0-9]+)\s*$', text)
if len(counts) != 1 or int(counts[0]) < 1:
    sys.exit(1)
print(counts[0])
PY
}

workspace_response() {
    local mode=$1 output=$2
    python3 - "$mode" "$output" <<'PY'
import json
import pathlib
import sys
import uuid

mode, path = sys.argv[1:]
try:
    payload = json.loads(pathlib.Path(path).read_text())
except (OSError, UnicodeError, ValueError):
    sys.exit(1)

matches = []
def visit(value):
    if isinstance(value, dict):
        if value.get('action') == mode and isinstance(value.get('workspaces'), list):
            matches.append(value)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)
    elif isinstance(value, str) and value.lstrip().startswith(('{', '[')):
        try:
            visit(json.loads(value))
        except ValueError:
            pass

visit(payload)
if len(matches) != 1 or matches[0].get('status') != 'ok':
    sys.exit(1)
workspaces = matches[0]['workspaces']
if mode == 'list':
    if not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in workspaces):
        sys.exit(1)
    if any(item['name'].casefold() == 'ow-probe' for item in workspaces):
        sys.exit(2)
else:
    if len(workspaces) != 1 or workspaces[0].get('name') != 'ow-probe':
        sys.exit(1)
    identifier = workspaces[0].get('id')
    if not isinstance(identifier, str):
        sys.exit(1)
    try:
        parsed = uuid.UUID(identifier)
    except ValueError:
        sys.exit(1)
    if identifier.lower() != str(parsed):
        sys.exit(1)
    print(identifier)
PY
}

warning_count() {
    local output=$1
    python3 - "$output" "$warning" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
print(sum(sys.argv[2] in line for line in lines))
PY
}

if ! "$cli" -e 'windows' >"$tmp_dir/windows-before.out" 2>"$tmp_dir/windows-before.err"; then
    fail 'debug app is not reachable through the debug CLI'
fi
before=$(window_count "$tmp_dir/windows-before.out") || fail 'cannot read the initial windows count'

if ! "$cli" --raw-json -e 'workspace list --include-hidden' >"$tmp_dir/list.out" 2>"$tmp_dir/list.err"; then
    fail 'cannot inspect the workspace list'
fi
workspace_response list "$tmp_dir/list.out"
case $? in
    0) ;;
    2) fail 'ow-probe already exists; refusing to create or delete it' ;;
    *) fail 'cannot verify the workspace list' ;;
esac

if ! "$cli" -e 'workspace switch rpce-one-window --new-window' >"$tmp_dir/switch.out" 2>"$tmp_dir/switch.err"; then
    fail 'workspace switch command failed'
fi
switch_warnings=$(warning_count "$tmp_dir/switch.err") || fail 'cannot inspect switch warning'
printf 'PROBE switch %s\n' "$switch_warnings"
[[ "$switch_warnings" == 1 ]] || fail 'switch did not emit exactly one expected warning line'

if "$cli" --raw-json -e 'workspace create ow-probe --new-window' >"$tmp_dir/create.out" 2>"$tmp_dir/create.err"; then
    created_maybe=1
else
    fail 'create command failed; inspect whether ow-probe needs manual cleanup'
fi
created_id=$(workspace_response create "$tmp_dir/create.out") || fail 'cannot verify the UUID returned by create'
create_warnings=$(warning_count "$tmp_dir/create.err") || fail 'cannot inspect create warning'
printf 'PROBE create %s\n' "$create_warnings"
[[ "$create_warnings" == 1 ]] || fail 'create did not emit exactly one expected warning line'

if ! "$cli" -w 1 -e 'workspace switch rpce-one-window --new-window' >"$tmp_dir/shorthand.out" 2>"$tmp_dir/shorthand.err"; then
    fail 'window-targeted shorthand command failed'
fi
shorthand_warnings=$(warning_count "$tmp_dir/shorthand.err") || fail 'cannot inspect shorthand warning'
printf 'PROBE shorthand %s\n' "$shorthand_warnings"
[[ "$shorthand_warnings" == 1 ]] || fail 'shorthand did not emit exactly one expected warning line'

if ! "$cli" -e 'windows' >"$tmp_dir/windows-after.out" 2>"$tmp_dir/windows-after.err"; then
    fail 'cannot inspect the final windows count'
fi
after=$(window_count "$tmp_dir/windows-after.out") || fail 'cannot read the final windows count'
printf 'WINDOWS before=%s after=%s\n' "$before" "$after"
[[ "$before" == "$after" ]] || fail 'window count changed'
