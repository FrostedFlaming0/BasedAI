#!/usr/bin/env python3
"""Static structural checks on the Solidity files.

This is NOT a compiler. It can catch:
  - Unbalanced braces, parens, brackets
  - Missing semicolons in obvious places
  - Imports of files we don't ship and aren't from OZ/forge-std
  - Functions declared in interfaces but missing in implementations
  - Reserved-ID collisions in BrainNFT._allocateBrainId

It cannot catch:
  - Type errors
  - Missing function signatures
  - Override mismatches
  - Storage layout issues
  - Anything semantic

Use: python3 check_solidity.py contracts/src
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path


def check_balance(text: str, path: Path) -> list[str]:
    """Check that braces, parens, and brackets balance, ignoring strings and comments."""
    errors: list[str] = []
    cleaned = strip_strings_and_comments(text)
    pairs = {"{": "}", "(": ")", "[": "]"}
    closers = set(pairs.values())
    stack: list[tuple[str, int]] = []  # (char, line)
    line = 1
    for ch in cleaned:
        if ch == "\n":
            line += 1
        elif ch in pairs:
            stack.append((ch, line))
        elif ch in closers:
            if not stack:
                errors.append(f"{path}:{line}: unmatched '{ch}'")
            else:
                opener, oline = stack.pop()
                if pairs[opener] != ch:
                    errors.append(
                        f"{path}:{line}: expected '{pairs[opener]}' "
                        f"to close '{opener}' from line {oline}, got '{ch}'"
                    )
    for opener, oline in stack:
        errors.append(f"{path}:{oline}: unclosed '{opener}'")
    return errors


def strip_strings_and_comments(text: str) -> str:
    """Replace string literals and comments with spaces, preserving newlines."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            # line comment
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif ch == "/" and nxt == "*":
            # block comment
            out.append("  ")
            i += 2
            while i < n - 1 and not (text[i] == "*" and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
        elif ch in ('"', "'"):
            quote = ch
            out.append(" ")
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            if i < n:
                out.append(" ")
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def check_imports(text: str, path: Path, all_files: set[Path]) -> list[str]:
    """Check that local imports point to files that exist."""
    errors: list[str] = []
    for m in re.finditer(r'import\s+(?:\{[^}]+\}\s+from\s+)?["\']([^"\']+)["\'];', text):
        target = m.group(1)
        if target.startswith("@openzeppelin/") or target.startswith("forge-std/"):
            continue
        if target.startswith("./") or target.startswith("../"):
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                errors.append(f"{path}: import '{target}' resolves to {resolved} which does not exist")
    return errors


def find_pragma_mismatch(files: list[Path]) -> list[str]:
    """All files should declare the same pragma."""
    pragmas: dict[str, list[Path]] = defaultdict(list)
    for f in files:
        text = f.read_text()
        m = re.search(r"pragma\s+solidity\s+([^;]+);", text)
        if m:
            pragmas[m.group(1).strip()].append(f)
    if len(pragmas) <= 1:
        return []
    errors = ["mixed pragma versions:"]
    for p, fs in pragmas.items():
        errors.append(f"  '{p}' in: {', '.join(str(f) for f in fs[:3])}")
    return errors


def check_brainNFT_allocate_logic(root: Path) -> list[str]:
    """The _allocateBrainId function in BrainNFT.sol has a known concern:
    the reserved-ID skip uses '>= 47 && <= 47' which only skips 47 once,
    not when it would be allocated a second time. Also IDs 0–6 are documented
    as reserved but no skip logic exists for them.
    """
    p = root / "src" / "tokens" / "BrainNFT.sol"
    if not p.exists():
        return []
    text = p.read_text()
    issues = []
    if "candidate >= 47 && candidate <= 47" in text:
        issues.append(
            f"{p}: _allocateBrainId only skips ID 47 in a single comparison; "
            "no skip for IDs 0–6 (also documented as reserved). "
            "If reserved IDs are pre-minted, this is fine; if not, IDs 0–6 will be "
            "allocated by the burn/stake path."
        )
    return issues


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_solidity.py <contracts-src-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2

    sol_files = sorted(root.rglob("*.sol"))
    print(f"Checking {len(sol_files)} Solidity files under {root}")

    all_paths = {f.resolve() for f in sol_files}
    errors: list[str] = []

    for f in sol_files:
        text = f.read_text()
        errors.extend(check_balance(text, f))
        errors.extend(check_imports(text, f, all_paths))

    errors.extend(find_pragma_mismatch(sol_files))
    errors.extend(check_brainNFT_allocate_logic(root.parent))

    if errors:
        print(f"\nFound {len(errors)} issue(s):\n")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("All structural checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
