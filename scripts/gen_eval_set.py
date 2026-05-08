#!/usr/bin/env python3
"""Generate a small eval set for validators.

Outputs a JSON file with prompt/reference pairs that validators use
to score miner quality. Pulls from a small curated set of factual
prompts with stable correct answers.
"""

import json
import sys
from pathlib import Path

EVAL_PROMPTS = [
    {
        "prompt": "What is 2 + 2? Reply with just the number.",
        "reference": "4",
    },
    {
        "prompt": "What is the capital of France? Reply with just the city name.",
        "reference": "Paris",
    },
    {
        "prompt": "Reply with the single word: PING",
        "reference": "PING",
    },
    {
        "prompt": "What year did the first humans land on the Moon? Reply with just the year.",
        "reference": "1969",
    },
    {
        "prompt": "What is the chemical symbol for gold? Reply with just the symbol.",
        "reference": "Au",
    },
    {
        "prompt": "How many days are in a non-leap year? Reply with just the number.",
        "reference": "365",
    },
    {
        "prompt": "What is the largest ocean on Earth? Reply with just the name.",
        "reference": "Pacific",
    },
    {
        "prompt": "What is H2O commonly known as? Reply with just the word.",
        "reference": "water",
    },
]


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "eval_set.json")
    out.write_text(json.dumps(EVAL_PROMPTS, indent=2))
    print(f"Wrote {len(EVAL_PROMPTS)} prompts to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
