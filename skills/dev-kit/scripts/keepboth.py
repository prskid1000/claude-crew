"""Resolve simple git conflict blocks by keeping OURS then THEIRS.

For append-only files where both sides added lines: Liquibase master.xml includes, route/nav lists, i18n keys,
DI registrations, barrel exports, requirements.txt, *.csproj item lists.
Never use it on real code conflicts. Re-run the build check afterwards.

  python keepboth.py <file> [<file> ...]
"""
import re, sys

pat = re.compile(r'<<<<<<< [^\r\n]*\r?\n(.*?)(?:\|\|\|\|\|\|\| [^\r\n]*\r?\n.*?)?=======\r?\n(.*?)>>>>>>> [^\r\n]*\r?\n', re.S)
for path in sys.argv[1:]:
    text = open(path, encoding='utf-8', newline='').read()
    n = len(pat.findall(text))
    text = pat.sub(lambda m: m.group(1) + m.group(2), text)
    open(path, 'w', encoding='utf-8', newline='').write(text)
    print(path, 'resolved', n, 'block(s)')
