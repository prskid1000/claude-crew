"""Outcome rules of localbench.py on hand-made answers (tests/local-bench.tests.ps1 runs it): prints FAIL lines. Usage: python tests/local_bench_cases.py <skills/crafty/adapters dir>. Exit codes: 0 pass, 1 a check failed."""
import json, sys
sys.path.insert(0, sys.argv[1])
import localbench as b  # noqa: E402

rv = {'verdict': 'changes', 'findings': [{'file': 'a.py', 'line': 10, 'severity': 'high', 'issue': 'null crash in parse_reply'},
                                         {'file': 'a.py', 'line': 20, 'severity': 'low', 'issue': 'unused import os'}]}
commit = 'feat(crafty): local bench replays recorded steps\n\n- crafty.ps1 local bench build run score report diff\n'
cases = [
    ('ship: the same commit text', {'commit': commit}, {'commit': commit}, True),
    ('ship: a spec that renders it', {'commit': commit}, {'type': 'feat', 'scope': 'crafty', 'change': 'local bench replays recorded steps', 'changes': [{'text': 'crafty.ps1 local bench build run score report diff'}]}, True),
    ('ship: another type', {'commit': commit}, {'commit': commit.replace('feat', 'fix', 1)}, False),
    ('a flipped verdict', {'verdict': 'changes', 'round': 2, 'task': 't1', 'summary': 'two findings'}, {'verdict': 'approve', 'round': 2, 'task': 't1', 'summary': 'two findings'}, False),
    ('a multi-word status', {'status': 'in test'}, {'status': 'in progress'}, False),
    ('plain strings item by item', {'checks': ['fail', 'fail']}, {'checks': ['pass', 'pass']}, False),
    ('keyless items: other prose', {'findings': [{'severity': 'blocking', 'issue': 'SQL injection in order search endpoint'}]}, {'findings': [{'severity': 'blocking', 'issue': 'typo in readme heading'}]}, False),
    ('same keys in swapped order', rv, {'verdict': 'changes', 'findings': list(reversed(rv['findings']))}, True),
    ('a wrong severity', rv, {'verdict': 'changes', 'findings': [dict(rv['findings'][0], severity='low'), rv['findings'][1]]}, False),
    ('an empty object', {'a': 'x', 'meta': {}}, {'a': 'x', 'meta': {}}, True),
    ('a number as a string', {'n': {'line': 12}}, {'n': {'line': '12'}}, True),
    ('true is not 1', {'ok2': True, 'x': 'a'}, {'ok2': 1, 'x': 'a'}, False),
    ('an echo is not an answer', {'summary': 'parse_reply crashes on null input'}, {'summary': 'parse_reply crashes on null input ' + ' '.join(f'word{i}x' for i in 400 * [0] for i in range(400))}, False),
]
bad = 0
for name, cloud, loc, want in cases:
    got, why = b.outcome(loc, cloud)
    if bool(got) != want:
        bad += 1
        print(f'FAIL outcome {name}: got {got} ({why}), want {want}')
for text, want in [('The kind of change is small.\nKind mr. Review it', 'mr'), ('Kind window / sweep', ''), ('Role test, kind task. Load pokey', 'task'), ('Role lead. publish', 'lead')]:
    if b.kind_of(text) != want:
        bad += 1
        print(f'FAIL kind_of {text!r}: {b.kind_of(text)!r}, want {want!r}')
for want, role, exp in [('kitty@', 'kitty:ship', False), ('kitty@', 'kitty@fix', True), ('revy', 'revy:review', True), ('revy@mr', 'revy@plan', False)]:
    if b.wanted(want, role) != exp:
        bad += 1
        print(f'FAIL wanted({want}, {role}): want {exp}')
body = (b.PREFIX + 'Do:\n1. read\n2. answer\n' + 'x' * 500 + b.CALLS_AT + '[1] Bash: ls\noutput:\nfile.txt\n' + b.SCHEMA_AT + ' (reply with the JSON object only) ===\n{"type": "object"}\n')
extra = [
    ('noformat drops the schema block', 'JSON SCHEMA' not in b.degrade(body, 'noformat') and 'file.txt' in b.degrade(body, 'noformat')),
    ('noformat drops the JSON-only line', 'Reply with the JSON object only: no prose' not in b.degrade(body, 'noformat')),
    ('vague cuts the steps', len(b.degrade(body, 'vague')) < len(body) - 90 and 'JSON SCHEMA' in b.degrade(body, 'vague')),
    ('noisy drops numbered steps, adds noise', '1. read' not in b.degrade(body, 'noisy') and 'heartbeat ok' in b.degrade(body, 'noisy')),
    ('deep schema names list item keys', b.deep_schema({'mrs': [{'url': 'u', 'merged': False}], 'n': 1})['properties']['mrs']['items']['properties']['merged'] == {'type': 'boolean'}),
    ('the final rule is read from AGENTS.md', 'StructuredOutput' in b.final_rule()),
]
for name, ok in extra:
    if not ok:
        bad += 1
        print(f'FAIL {name}')
print(f'{len(cases) + 8 + len(extra) - bad} ok, {bad} failed')
sys.exit(1 if bad else 0)
