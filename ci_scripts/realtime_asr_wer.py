#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path

TOKEN_PATTERN = re.compile(
    r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]|[a-z0-9_]+(?:'[a-z0-9_]+)*"
)


def words(text: str) -> list[str]:
    return TOKEN_PATTERN.findall(text.lower())


def score(reference: list[str], hypothesis: list[str]) -> dict:
    if not reference:
        raise ValueError("Reference transcript contains no scorable tokens.")

    prev = [(0, 0, index) for index in range(len(hypothesis) + 1)]
    for reference_index, reference_word in enumerate(reference, start=1):
        curr = [(0, reference_index, 0)]
        for hypothesis_index, hypothesis_word in enumerate(hypothesis, start=1):
            if reference_word == hypothesis_word:
                curr.append(prev[hypothesis_index - 1])
                continue
            substitution = prev[hypothesis_index - 1]
            deletion = prev[hypothesis_index]
            insertion = curr[hypothesis_index - 1]
            candidates = (
                (substitution[0] + 1, substitution[1], substitution[2]),
                (deletion[0], deletion[1] + 1, deletion[2]),
                (insertion[0], insertion[1], insertion[2] + 1),
            )
            curr.append(min(candidates, key=sum))
        prev = curr

    substitutions, deletions, insertions = prev[-1]
    errors = substitutions + deletions + insertions
    reference_count = len(reference)
    return {
        "reference_words": reference_count,
        "hypothesis_words": len(hypothesis),
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "errors": errors,
        "wer": errors / reference_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Calculate word error rate for realtime ASR output.")
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--hypothesis", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    ref_tokens = words(args.reference.read_text(encoding="utf-8"))
    hyp_tokens = words(args.hypothesis.read_text(encoding="utf-8"))
    if not ref_tokens:
        sys.exit("Error: reference transcript contains no scorable tokens.")
    result = score(ref_tokens, hyp_tokens)
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()
