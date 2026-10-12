"""Kit paths for Python: the only place a .py learns where runtime or durable local state lives (map: kitpaths.json).

  sys.path.insert(0, '<kit>/skills/dev-kit/scripts'); from kitpaths import kit_path, KIT
  kit_path('qa-runs')               # <runtime>/work/qa-runs        ('runtime' = the runtime root)
  kit_path('kit-flow', create=True) # creates the folder (or a file's parent folder) first
  kit_path('tracking')              # <kit>/tracking.local.json     (durable, git-ignored)
  with locked(kit_path('tracking')): ...   # the same <file>.lock protocol as kitpaths.ps1 Invoke-KitLocked

<runtime> = $CLAUDE_RUNTIME, else <kit>/.claude-runtime.
"""
import contextlib, json, os, time

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))   # <kit>/skills/dev-kit/scripts -> <kit>
with open(os.path.join(HERE, 'kitpaths.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)


def runtime_dir(kit=None):
    return os.environ.get('CLAUDE_RUNTIME') or os.path.join(kit or KIT, MAP['runtimeDir'])


def kit_path(name, create=False, kit=None):
    """Absolute path of a named runtime or durable entry. kit= resolves it for another kit folder (kit-lint on a clone)."""
    if name == 'runtime':
        p, is_dir = runtime_dir(kit), True
    elif name in MAP['runtime']:
        rel = MAP['runtime'][name]
        p, is_dir = os.path.join(runtime_dir(kit), rel.rstrip('/')), rel.endswith('/')
    elif name in MAP['durable']:
        rel = MAP['durable'][name]
        p, is_dir = os.path.join(kit or KIT, rel.rstrip('/')), rel.endswith('/')
    else:
        raise KeyError(f'kit_path: unknown name {name!r} (see skills/dev-kit/scripts/kitpaths.json)')
    p = os.path.normpath(p)
    if create:
        os.makedirs(p if is_dir else os.path.dirname(p), exist_ok=True)
    return p


@contextlib.contextmanager
def locked(path, stale=120):
    lock = path + '.lock'
    fd = None
    end = time.time() + stale + 10   # a dead writer's lock turns stale (and is taken over) before we give up
    while fd is None:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > stale:
                    os.remove(lock)
                    continue
            except OSError:
                pass
            if time.time() > end:   # never run the body unlocked (that lost concurrent writes)
                raise TimeoutError(f'could not lock {path} within {stale + 10} s ({lock} is held)')
            time.sleep(0.1)
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
            try:
                os.remove(lock)
            except OSError:
                pass
