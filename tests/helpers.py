"""Load bin/eld-unifi-protect as a module, isolated from the real user.

The helper reads XDG_* variables when it is imported, so they point at a
throwaway directory before loading: tests never see or touch real config,
state, API keys or the running relay.
"""

import atexit
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SANDBOX = tempfile.mkdtemp(prefix="eld-unifi-protect-test-")
atexit.register(shutil.rmtree, SANDBOX, ignore_errors=True)
os.chmod(SANDBOX, 0o700)
for name in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
    path = os.path.join(SANDBOX, name.lower())
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.environ[name] = path


def load_helper():
    path = str(ROOT / "bin" / "eld-unifi-protect")
    loader = importlib.machinery.SourceFileLoader("eld_unifi_protect", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()
