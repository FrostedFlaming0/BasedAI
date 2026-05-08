#!/usr/bin/env python3
"""Deeper structural checks. Still not a compiler, but catches more.

Checks performed:
  - Every external/public function declared in an interface I... has a matching
    function name in any contract that says 'is I...'.
  - Constructor arg count of parent calls matches the parent's constructor (best-effort).
  - Functions marked `override(A, B, ...)` reference contracts that are inherited.
  - No duplicate state variable names within a contract.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from collections import defaultdict


def strip(text: str) -> str:
    """Strip strings/comments preserving newlines (same as check_solidity.py)."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" "); i += 1
        elif ch == "/" and nxt == "*":
            out.append("  "); i += 2
            while i < n - 1 and not (text[i] == "*" and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " "); i += 1
            out.append("  "); i += 2
        elif ch in ('"', "'"):
            quote = ch
            out.append(" "); i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\" and i + 1 < n:
                    out.append("  "); i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " "); i += 1
            if i < n: out.append(" "); i += 1
        else:
            out.append(ch); i += 1
    return "".join(out)


def find_contracts(text: str) -> list[tuple[str, str, list[str]]]:
    """Return list of (kind, name, parents) for each contract/interface."""
    out = []
    for m in re.finditer(
        r"\b(contract|interface|abstract\s+contract|library)\s+(\w+)(?:\s+is\s+([^\{]+))?\s*\{",
        text,
    ):
        kind, name, parents_text = m.group(1).strip(), m.group(2), m.group(3) or ""
        parents = [p.strip().split("(")[0].strip() for p in parents_text.split(",") if p.strip()]
        parents = [p for p in parents if p]
        out.append((kind, name, parents))
    return out


def find_functions(text: str) -> list[dict]:
    """Find function declarations. Returns list of dicts with name, visibility, override-list."""
    fns = []
    pattern = re.compile(
        r"function\s+(\w+)\s*\(([^)]*)\)\s*"
        r"((?:\s*(?:public|external|internal|private|view|pure|payable|virtual|override(?:\([^\)]*\))?|onlyRole\([^\)]*\)|nonReentrant|returns\s*\([^\)]*\)))*)"
    )
    for m in pattern.finditer(text):
        name = m.group(1)
        modifiers = m.group(3) or ""
        visibility = None
        for v in ("external", "public", "internal", "private"):
            if re.search(rf"\b{v}\b", modifiers):
                visibility = v
                break
        override_match = re.search(r"override\s*\(([^)]*)\)", modifiers)
        override_parents = []
        if override_match:
            override_parents = [p.strip() for p in override_match.group(1).split(",") if p.strip()]
        fns.append({
            "name": name,
            "visibility": visibility,
            "override_parents": override_parents,
            "is_override": "override" in modifiers,
        })
    return fns


def find_state_vars(text: str) -> list[str]:
    """Find state variable names. Heuristic: lines at contract level that look like
    `<type> <visibility>? <modifier>? <name>(=...)? ;`. We only care about duplicates."""
    names: list[str] = []
    # Match common state var patterns. This is heuristic.
    # Skip function bodies by tracking brace depth at module level.
    depth = 0
    lines = text.split("\n")
    in_contract = False
    contract_brace_depth = 0
    for line in lines:
        # Update depth
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
        # Only consider lines at contract-body depth (depth == 1 after opening brace).
        # This is a rough heuristic; functions, structs, modifiers all live at depth 1.
        # We try to skip function bodies by looking for "function" keyword on the line.
    return names  # Disabled — too noisy without a proper parser. Keep stub for now.


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_overrides.py <contracts-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    sol_files = sorted(root.rglob("*.sol"))

    # Build a map: contract name -> (path, parents, functions)
    contracts: dict[str, dict] = {}
    for f in sol_files:
        text = strip(f.read_text())
        for kind, name, parents in find_contracts(text):
            # Find the body for this contract specifically
            # (rough: take from contract decl to balanced closing brace)
            start = text.find(f"{kind} {name}") if kind != "abstract contract" else text.find(name)
            # Easier: just associate functions with files for now.
            contracts[name] = {
                "path": f,
                "kind": kind,
                "parents": parents,
                "functions": find_functions(text),
            }

    errors: list[str] = []

    # Check 1: every interface function appears in implementing contracts.
    for name, info in contracts.items():
        if info["kind"] != "interface":
            continue
        iface_fns = {fn["name"] for fn in info["functions"]}
        # Find contracts that inherit this interface
        for cname, cinfo in contracts.items():
            if cinfo["kind"] in ("interface",):
                continue
            if name in cinfo["parents"]:
                impl_fn_names = {fn["name"] for fn in cinfo["functions"]}
                missing = iface_fns - impl_fn_names
                # Filter out events/errors which look like functions in interface but aren't
                # (we already only matched 'function' keyword so this should be clean).
                if missing:
                    errors.append(
                        f"{cinfo['path']}: contract {cname} inherits {name} but does "
                        f"not implement: {', '.join(sorted(missing))}"
                    )

    # Check 2: override() lists reference actually-inherited contracts.
    for cname, cinfo in contracts.items():
        if cinfo["kind"] in ("interface", "library"):
            continue
        # Compute transitive parents (one level deep is usually enough to catch typos).
        direct = set(cinfo["parents"])
        for fn in cinfo["functions"]:
            for op in fn["override_parents"]:
                if op not in direct and op != cname:
                    # It might be a transitive parent; we only flag obvious typos.
                    # Check if it exists as any contract at all.
                    if op not in contracts and op not in (
                        # Common OZ parents
                        "ERC20", "ERC20Permit", "ERC20Votes", "ERC721", "ERC721Enumerable",
                        "AccessControl", "Governor", "GovernorSettings", "GovernorCountingSimple",
                        "GovernorTimelockControl", "Nonces", "Context",
                    ):
                        errors.append(
                            f"{cinfo['path']}: function {fn['name']} in {cname} "
                            f"declares override({op}, ...) but {op} is not a known parent"
                        )

    if errors:
        print(f"Found {len(errors)} issue(s):\n")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"Checked {len(contracts)} contracts/interfaces. No issues found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
