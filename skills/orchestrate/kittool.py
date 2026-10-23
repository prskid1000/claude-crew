# shim: remove after 2026-11-23 (the #7 rename: kittool.py -> skills/bossy/kitbag.py, for callers outside the kit)
import os, runpy, sys
sys.argv[0] = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bossy', 'kitbag.py'))
runpy.run_path(sys.argv[0], run_name='__main__')
