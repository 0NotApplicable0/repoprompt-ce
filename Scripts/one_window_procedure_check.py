#!/usr/bin/env python3
"""Check the shared one-window workspace procedure and published guidance."""

import argparse
import bisect
import re
import sys
from dataclasses import dataclass
from pathlib import Path


COMMON_PINS = (
    "Open a workspace on the existing window. Do not open a new window.",
    "Address the workspace by name or id. The window's focused workspace is not the agent's workspace.",
    "Do not read or set ui.orchestration_graph_enabled in order to open a workspace.",
    "Then bind_context op=bind workspace=<name or id>.",
    "On status conflict: report the conflict block to the seat that started you and stop.",
    "Never retry a conflict and never change file_system.* to resolve it.",
)
ROLE_PINS = {
    "REPOPROMPT.md": "Workspace procedure: manage_workspaces list; add missing roots to the vision workspace, else create it.",
    "agents/aidlc-em.md": "Workspace procedure: manage_workspaces list; add missing roots to the vision workspace, else create it.",
    "agents/aidlc-tl.md": "Workspace procedure: manage_workspaces list; a missing workspace or root is reported to the EM, who creates it.",
    "agents/aidlc-worker.md": "Workspace procedure: manage_workspaces list; a missing workspace or root is reported to your TL; never create one.",
}
CONTEXT_FILES = (
    "contexts/aidlc/repoprompt-topology.md",
    "contexts/repoprompt-reference.md",
)
WORKFLOW_FILE = "Sources/RepoPromptShared/Workflows/WorkflowPromptSharedFragments.swift"
ROUTING_FILE = "Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift"
KEEP_PHRASE = "never creates a workspace"
EXEMPT_SENTENCE = "open_in_new_window is deprecated and ignored; workspaces open on the existing window."
FORBIDDEN = (
    "new window",
    "second window",
    "another window",
    "another main window",
    "opens a window",
    "open a window",
    "OG-06",
    "graph flag",
    "orchestration graph is",
    "refuses a window holding live sessions",
    "Confirm termination to proceed",
)
SENTENCE_BREAK = re.compile(r"(?<=[.!?])\s+")


@dataclass(frozen=True)
class Literal:
    start: int
    text: str


class SwiftLiterals:
    """Extract ordinary/triple Swift literals, excluding comments and interpolation code."""

    def __init__(self, source: str):
        self.source = source
        self.code = list(source)
        self.literals: list[Literal] = []
        self.scan_code(0)

    def mask(self, start: int, end: int) -> None:
        for index in range(start, end):
            if self.code[index] != "\n":
                self.code[index] = " "

    def scan_code(self, start: int, interpolation: bool = False) -> int:
        source = self.source
        index = start
        depth = 1 if interpolation else 0
        while index < len(source):
            if source.startswith("//", index):
                end = source.find("\n", index)
                if end < 0:
                    end = len(source)
                self.mask(index, end)
                index = end
            elif source.startswith("/*", index):
                beginning = index
                nesting = 1
                index += 2
                while index < len(source) and nesting:
                    if source.startswith("/*", index):
                        nesting += 1
                        index += 2
                    elif source.startswith("*/", index):
                        nesting -= 1
                        index += 2
                    else:
                        index += 1
                if nesting:
                    raise ValueError("unterminated Swift block comment")
                self.mask(beginning, index)
            elif source[index] == '"':
                index = self.scan_string(index)
            elif interpolation and source[index] == "(":
                depth += 1
                index += 1
            elif interpolation and source[index] == ")":
                depth -= 1
                index += 1
                if depth == 0:
                    return index
            else:
                index += 1
        if interpolation:
            raise ValueError("unterminated Swift string interpolation")
        return index

    def scan_string(self, start: int) -> int:
        source = self.source
        delimiter = '"""' if source.startswith('"""', start) else '"'
        content_start = start + len(delimiter)
        index = content_start
        interpolations: list[tuple[int, int]] = []
        while index < len(source):
            if source[index] == "\\":
                if source.startswith("\\(", index):
                    end = self.scan_code(index + 2, interpolation=True)
                    interpolations.append((index, end))
                    index = end
                else:
                    index += 2
            elif source.startswith(delimiter, index):
                content = list(source[content_start:index])
                for beginning, end in interpolations:
                    for position in range(beginning, end):
                        if source[position] != "\n":
                            content[position - content_start] = " "
                self.literals.append(Literal(content_start, "".join(content)))
                end = index + len(delimiter)
                self.mask(start, end)
                return end
            else:
                index += 1
        raise ValueError("unterminated Swift string literal")


class Checker:
    def __init__(self):
        self.failed = False

    def report(self, kind: str, path: Path, line: int | None, text: str) -> None:
        location = f"{path} {line}" if line is not None else str(path)
        print(f"{kind} {location} {text}")
        if kind in ("MISSING", "SENTENCE"):
            self.failed = True

    def check_pins(self, path: Path, source: str, role: str) -> set[int]:
        lines = source.splitlines()
        exempt_lines: set[int] = set()
        for pin in (ROLE_PINS[role], *COMMON_PINS):
            found = [number for number, line in enumerate(lines, 1) if line == pin]
            for number in found:
                self.report("NEED", path, number, pin)
                exempt_lines.add(number)
            if len(found) != 1:
                self.report("MISSING", path, None, pin)
        if role == "agents/aidlc-worker.md":
            found = [number for number, line in enumerate(lines, 1) if KEEP_PHRASE in line]
            for number in found:
                self.report("KEEP", path, number, lines[number - 1])
            if len(found) != 1:
                self.report("MISSING", path, None, KEEP_PHRASE)
        return exempt_lines

    def check_prose(self, path: Path, source: str, exempt_lines: set[int] | None = None) -> None:
        for number, line in enumerate(source.splitlines(), 1):
            if exempt_lines is not None and number in exempt_lines:
                continue
            self.check_line(path, number, line)

    def check_line(self, path: Path, number: int, line: str) -> None:
        # Schema descriptions may follow a type label after alignment spaces.
        for field in re.split(r"\s{2,}", line):
            for sentence in SENTENCE_BREAK.split(field):
                sentence = sentence.strip()
                if sentence == EXEMPT_SENTENCE:
                    continue
                if any(token.casefold() in sentence.casefold() for token in FORBIDDEN):
                    self.report("SENTENCE", path, number, sentence)

    def check_swift(self, path: Path, source: str, published_tools_only: bool = False) -> None:
        lexer = SwiftLiterals(source)
        literals = lexer.literals
        if published_tools_only:
            code = "".join(lexer.code)
            regions = []
            for name in ("bindContext", "manageWorkspaces"):
                pattern = rf"\bTool\s*\(\s*name:\s*MCPGlobalToolName\.{name}\s*,"
                matches = list(re.finditer(pattern, code))
                if len(matches) != 1:
                    raise ValueError(f"expected one published {name} Tool, found {len(matches)}")
                start = matches[0].end()
                description = re.search(r"\bdescription\s*:", code[start:])
                if description is None:
                    raise ValueError(f"missing {name} Tool description")
                start += description.end()
                annotation = re.search(r"\bannotations\s*:", code[start:])
                if annotation is None:
                    raise ValueError(f"missing {name} Tool annotations")
                end = start + annotation.start()
                if not re.search(r"\binputSchema\s*:", code[start:end]):
                    raise ValueError(f"missing {name} Tool inputSchema")
                regions.append((start, end))
            literals = [literal for literal in literals if any(start <= literal.start < end for start, end in regions)]
        line_starts = [0] + [match.end() for match in re.finditer("\n", source)]
        for literal in sorted(literals, key=lambda item: item.start):
            offset = 0
            for line in literal.text.splitlines(keepends=True):
                number = bisect.bisect_right(line_starts, literal.start + offset)
                self.check_line(path, number, line.rstrip("\r\n"))
                offset += len(line)


def read_source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness-root", type=Path, default=Path("/Users/dev/.custom-agents"))
    parser.add_argument("--product-root", type=Path, default=Path("."))
    parser.add_argument("--extra", type=Path, action="append", default=[])
    args = parser.parse_args()
    checker = Checker()
    try:
        for role in ROLE_PINS:
            path = args.harness_root / role
            source = read_source(path)
            checker.check_prose(path, source, checker.check_pins(path, source, role))
        for relative in CONTEXT_FILES:
            path = args.harness_root / relative
            checker.check_prose(path, read_source(path))
        for relative in (WORKFLOW_FILE, ROUTING_FILE):
            path = args.product_root / relative
            checker.check_swift(path, read_source(path), published_tools_only=relative == ROUTING_FILE)
        for path in args.extra:
            source = read_source(path)
            if path.suffix.lower() == ".swift":
                checker.check_swift(path, source)
            else:
                checker.check_prose(path, source)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 2
    return 1 if checker.failed else 0


if __name__ == "__main__":
    sys.exit(main())
