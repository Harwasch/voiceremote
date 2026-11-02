"""Purpose: reproducible metrics and gate. Inputs: validated export. Verified by synthetic tests."""
import math
import re
import unicodedata


def tokens(text):
    """NFKC + casefold; punctuation separates words; numbers receive no special rewriting."""
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", unicodedata.normalize("NFKC", text).casefold())


def align(reference, hypothesis):
    """Levenshtein alignment, ties: diagonal, deletion, insertion. Return errors and ref map."""
    n, m = len(reference), len(hypothesis)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dp[i][0] = i
    for j in range(m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = min(dp[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]),
                           dp[i - 1][j] + 1, dp[i][j - 1] + 1)
    mapping = {}
    i, j = n, m
    while i or j:
        if i and j and dp[i][j] == dp[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            mapping[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif i and dp[i][j] == dp[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return dp[n][m], mapping


def stt_metrics(cases, results, vocabulary):
    indexed = {r["case_id"]: r for r in results}
    words = errors = term_total = term_errors = first_deleted = 0
    clipped = []
    for case in cases:
        row = indexed[case["id"]]
        ref, hyp = tokens(case["expected_text"]), tokens(row["text"])
        distance, mapping = align(ref, hyp)
        words += len(ref)
        errors += distance
        first_deleted += 0 not in mapping
        if "clipped_first_word" in row:
            clipped.append(row["clipped_first_word"])
        for term in vocabulary:
            term = tokens(term)
            for start in range(len(ref) - len(term) + 1):
                if ref[start:start + len(term)] != term:
                    continue
                term_total += 1
                positions = [mapping.get(k) for k in range(start, start + len(term))]
                correct = (None not in positions
                           and positions == list(range(positions[0], positions[0] + len(term)))
                           and [hyp[p] for p in positions] == term)
                term_errors += not correct
    return dict(wer=errors / words, errors=errors, words=words,
                term_errors=term_errors, term_total=term_total,
                term_accuracy=1 - term_errors / term_total if term_total else None,
                clipped=sum(clipped), clipped_n=len(clipped), first_deleted=first_deleted)


def timing(results, field):
    values = sorted(row[field] for row in results if field in row)
    if not values:
        return "TBD (n=0)"
    return f"{sum(values) / len(values):.1f} / {values[math.ceil(.95 * len(values)) - 1]:.1f} (n={len(values)})"


def battery(engine):
    sample = engine.get("battery")
    if sample is None:
        return "TBD"
    return f'{sample["drain_percentage_points"] * 600 / sample["duration_seconds"]:.3f} pp'


def gate(candidate, baseline, threshold):
    if baseline is None:
        return "INCOMPLETE: Apple baseline missing"
    if not baseline["term_total"]:
        return "INCOMPLETE: no vocabulary occurrences"
    if not baseline["term_errors"]:
        return "FAIL: Apple has zero term errors"
    reduction = 1 - candidate["term_errors"] / baseline["term_errors"]
    if candidate["wer"] >= baseline["wer"]:
        return "FAIL: WER does not beat Apple"
    if candidate["term_errors"] >= baseline["term_errors"] or reduction + 1e-12 < threshold:
        return f"FAIL: term error reduction {reduction:.1%}"
    return f"PASS: term error reduction {reduction:.1%}"
