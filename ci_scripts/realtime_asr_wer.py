#!/usr/bin/env python3

import argparse
import json
import re
from pathlib import Path


def words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.lower(), flags=re.UNICODE)


def score(reference: list[str], hypothesis: list[str]) -> dict:
    rows = [[(0, 0, index, 0) for index in range(len(hypothesis) + 1)]]
    rows[0] = [(0, 0, index, 0) for index in range(len(hypothesis) + 1)]
    for reference_index, reference_word in enumerate(reference, start=1):
        row = [(0, reference_index, 0, 0)]
        for hypothesis_index, hypothesis_word in enumerate(hypothesis, start=1):
            if reference_word == hypothesis_word:
                row.append(rows[-1][hypothesis_index - 1])
                continue
            substitution = rows[-1][hypothesis_index - 1]
            deletion = rows[-1][hypothesis_index]
            insertion = row[hypothesis_index - 1]
            candidates = [
                (sum(substitution) + 1, (substitution[0] + 1, substitution[1], substitution[2], substitution[3])),
                (sum(deletion) + 1, (deletion[0], deletion[1] + 1, deletion[2], deletion[3])),
                (sum(insertion) + 1, (insertion[0], insertion[1], insertion[2] + 1, insertion[3])),
            ]
            row.append(min(candidates, key=lambda item: item[0])[1])
        rows.append(row)
    substitutions, deletions, insertions, _ = rows[-1][-1]
    errors = substitutions + deletions + insertions
    reference_count = len(reference)
    return {
        "reference_words": reference_count,
        "hypothesis_words": len(hypothesis),
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "errors": errors,
        "wer": errors / reference_count if reference_count else 0.0,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Calculate word error rate for realtime ASR output.")
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--hypothesis", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    result = score(
        words(args.reference.read_text(encoding="utf-8")),
        words(args.hypothesis.read_text(encoding="utf-8")),
    )
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()
