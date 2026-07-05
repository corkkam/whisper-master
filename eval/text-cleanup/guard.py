"""Python port of Sources/WhisperMaster/Transcription/CleanupFaithfulnessGuard.swift.

Kept in sync with the shipped Swift guard so the eval can report whether a given
model's misbehaviors would be caught before reaching the user. `accept(original,
cleaned)` returns True if the cleanup is plausibly faithful, False if the caller
should discard it and keep the deterministic text.
"""
import re
from collections import Counter

MAX_EXPANSION_RATIO = 1.6
MIN_RETENTION_RATIO = 0.3
TRUNCATION_FLOOR_MIN_WORDS = 5

STOPWORDS = {
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "am",
    "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
    "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
    "to", "of", "in", "on", "at", "for", "with", "and", "or", "but", "so", "if",
    "then", "as", "by", "from", "up", "out", "about", "into", "over", "off",
    "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
    "should", "may", "might", "must", "not", "no", "yes", "there", "here",
    "what", "when", "where", "who", "why", "how", "which", "whom", "whose",
}
FILLERS = {
    "um", "umm", "uh", "uhh", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "mmm",
    "mhm", "like", "well", "okay", "ok", "yeah", "just", "really", "actually",
    "basically", "literally", "sorta", "kinda",
}
NUMBER_WORDS = {
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "thousand", "million", "billion", "dozen", "oh", "point", "half",
}
CONTRACTIONS = [
    ("won't", "will not"), ("can't", "can not"), ("n't", " not"),
    ("i'm", "i am"), ("let's", "let us"), ("'ll", " will"),
    ("'re", " are"), ("'ve", " have"), ("'d", " would"),
    ("it's", "it is"), ("that's", "that is"), ("what's", "what is"),
    ("he's", "he is"), ("she's", "she is"), ("there's", "there is"),
]


def _expand(s):
    for a, b in CONTRACTIONS:
        s = s.replace(a, b)
    return s


def _stem(w):
    for suf in ("ing", "ed", "es", "s"):
        if len(w) > len(suf) + 2 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def _alpha_tokens(s):
    return [t for t in re.findall(r"\w+", _expand(s.lower()), re.UNICODE) if t.isalpha()]


def _content_tokens(s):
    out = []
    for t in re.findall(r"\w+", _expand(s.lower()), re.UNICODE):
        if (len(t) > 1 and t.isalpha() and t not in STOPWORDS
                and t not in FILLERS and t not in NUMBER_WORDS):
            out.append(t)
    return out


def accept(original, cleaned):
    out = (cleaned or "").strip()
    if not out:
        return False
    if "```" in out:
        return False

    iw = len(original.split())
    ow = len(out.split())
    if iw > 0:
        ratio = ow / iw
        if ratio > MAX_EXPANSION_RATIO:
            return False
        if iw >= TRUNCATION_FLOOR_MIN_WORDS and ratio < MIN_RETENTION_RATIO:
            return False

    if _content_tokens(original) and not _content_tokens(out):
        return False

    input_counts = Counter(_stem(t) for t in _alpha_tokens(original))
    output_counts = Counter(_stem(t) for t in _content_tokens(out))
    for word, count in output_counts.items():
        if count > input_counts.get(word, 0):
            return False
    return True
