#!/usr/bin/env python3
"""Stream an mbox on stdin; emit one TSV row per message on stdout.

Columns: date_utc, from_addr, msgid, is_thread_start, has_patch, ai_hit, ai_terms, subject
Bodies are only scanned, never stored.
"""
import sys, re, email, email.utils, email.policy
from email.parser import BytesParser
from datetime import timezone

PATCH_FN = re.compile(rb'(?im)^\s*(?:content-disposition|content-type):[^\n]*(?:\n[ \t][^\n]*)*?name\*?=\s*"?[^"\n;]*\.(?:patch|diff|patch\.gz|diff\.gz|tar\.gz|tgz)\b')
PATCH_BODY = re.compile(rb'(?m)^(?:diff --git a/|Index: [^\n]+\n={20,}|--- a/[^\n]+\n\+\+\+ b/)')

# AI / LLM terms. Matched only on non-quoted lines (not starting with '>').
AI_TERMS = [
    ('chatgpt', r'\bchat\s?gpt\b'),
    ('gpt-n', r'\bgpt-?[345](?:\.\d|o)?\b'),
    ('openai', r'\bopenai\b'),
    ('claude', r'\bclaude(?:\s+code|\s+(?:opus|sonnet|haiku))?\b'),
    ('anthropic', r'\banthropic\b'),
    ('copilot', r'\bcopilot\b'),
    ('gemini', r'\bgemini\b'),
    ('cursor-ai', r'\bcursor\s+(?:ai|ide|editor)\b'),
    ('codex', r'\b(?:openai\s+)?codex\b'),
    ('llm', r'\bllms?\b|\blarge language models?\b'),
    ('ai-assist', r'\bai[- ](?:assisted|generated|tools?|agents?|assistants?|coding|written|model)\b|\bwith (?:the help of )?(?:an? )?ai\b|\bgenerative ai\b|\bvibe[- ]cod'),
    ('ai-trailer', r'(?:co-authored-by|assisted-by|generated-by):\s*(?:claude|chatgpt|gpt|copilot|gemini|cursor|codex|ai\b)|generated with \[?claude'),
]
AI_RE = [(n, re.compile(p, re.I)) for n, p in AI_TERMS]

parser = BytesParser(policy=email.policy.compat32)


def text_of(msg):
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        ct = part.get_content_type()
        if not (ct.startswith('text/') or ct in ('application/octet-stream', 'application/x-patch')):
            continue
        try:
            payload = part.get_payload(decode=True)
        except Exception:
            payload = None
        if not payload or len(payload) > 4_000_000:
            continue
        out.append(payload.decode('utf-8', 'replace'))
    return '\n'.join(out)


def handle(raw):
    try:
        msg = parser.parsebytes(raw)
    except Exception:
        return
    frm = email.utils.parseaddr(str(msg.get('From', '') or ''))[1].lower()
    msgid = str(msg.get('Message-ID', '') or '').strip()
    irt = str(msg.get('In-Reply-To') or '').strip()
    refs = str(msg.get('References') or '').strip()
    subj = str(msg.get('Subject', '') or '').replace('\t', ' ').replace('\n', ' ')[:200]
    try:
        dt = email.utils.parsedate_to_datetime(str(msg.get('Date')))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        d = dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
    except Exception:
        d = ''
    start = 0 if (irt or refs) else 1
    has_patch = 1 if (PATCH_FN.search(raw) or PATCH_BODY.search(raw)) else 0
    body = text_of(msg)
    lines = [l for l in body.splitlines() if not l.lstrip().startswith('>')]
    # drop everything after a typical "On ... wrote:" quote header that is followed only by quotes
    txt = '\n'.join(lines) + '\n' + subj
    hits = sorted({n for n, r in AI_RE if r.search(txt)})
    print('\t'.join([d, frm, msgid, str(start), str(has_patch), '1' if hits else '0', ','.join(hits), subj]))


def main():
    buf = []
    prev_blank = True
    for line in sys.stdin.buffer:
        if line.startswith(b'From ') and prev_blank and buf:
            handle(b''.join(buf[1:]))
            buf = []
        buf.append(line)
        prev_blank = line in (b'\n', b'\r\n')
    if buf:
        handle(b''.join(buf[1:]))


if __name__ == '__main__':
    main()
