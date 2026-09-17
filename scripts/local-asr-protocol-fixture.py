"""Protocol fixture only. Does not load or download speech models."""
import json
from pathlib import Path
import sys
import time
import signal
import os

assert sys.flags.isolated == 1
assert os.environ.get("PIP_CONFIG_FILE") == "/dev/null"
assert not any(name in os.environ for name in ("PYTHONHOME", "PYTHONPATH", "PIP_INDEX_URL", "HF_ENDPOINT", "HF_TOKEN"))

print(json.dumps({"ready": True}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if request.get("language") == "error":
        print(json.dumps({"error": "fixture error"}), flush=True)
    elif request.get("language") == "hang":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
    else:
        assert Path(request["path"]).read_bytes() == b"test"
        print(json.dumps({"progress": .5}), flush=True)
        print(json.dumps({"text": "protocol ok"}), flush=True)
