"""devtools.py offline checks: a missing MR/solution body file is refused; mergeAfter pairs find the producer and warn on a repo
name that does not match the remote.   python -X utf8 <kit>/skills/dev-kit/tests/test_devtools.py   (exit 0 = all pass)"""
import contextlib, importlib.util, io, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('devtools', os.path.join(HERE, '..', 'scripts', 'devtools.py'))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
fails = 0


def expect(what, cond):
    global fails
    print(('PASS ' if cond else 'FAIL ') + what)
    fails += 0 if cond else 1


try:
    d._body('no-such-body.md')
    expect('a missing body file is refused', False)
except SystemExit as e:
    expect('a missing body file is refused', 'file not found' in str(e))
expect('multi-line body text passes as it is', d._body('a\nb') == 'a\nb')

fd, path = tempfile.mkstemp(suffix='.json')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump({'tasks': {'T1': {'mergeAfter': ['web!5>api!3', 'other!5>api!4']}}}, f)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    out = d.unmerged_producers('group/web', '5', lambda r, i: 'opened', tracking=path)
os.remove(path)
expect('the open producer is found', out == [('api!3', 'opened', 'T1')])
expect('a pair naming another repo is reported, not silently skipped', 'names repo other' in err.getvalue())
expect('merge_word reads the last line', d.merge_word('x\nWAIT') == 'WAIT' and d.merge_word('x') == 'NOT_MERGED')
print(f'{fails} failure(s)')
sys.exit(1 if fails else 0)
