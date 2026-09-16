"""Exercise an installed Qwen 0.6B worker; never changes the selected app model."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import numpy as np
import soundfile as sf

ROOT = Path.home() / "Library/Application Support/SuperDictate/LocalModels"
SCRIPT = Path(__file__).resolve().parents[1] / "swift/Resources/local-asr.py"


def main():
    rss = []
    with tempfile.TemporaryDirectory(prefix="asr-resource-check-") as temporary:
        directory = Path(temporary)
        aiff = directory / "speech.aiff"
        subprocess.run(["/usr/bin/say", "-v", "Milena", "-o", str(aiff),
                        "Проверяем распознавание. Это короткая тестовая фраза."], check=True)
        from scipy.signal import resample_poly
        from math import gcd
        audio, rate = sf.read(aiff, dtype="float32")
        factor = gcd(rate, 16000)
        audio = resample_poly(audio, 16000 // factor, rate // factor)
        sample = directory / "speech.f32"
        np.asarray(audio, dtype="<f4").tofile(sample)
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", TOKENIZERS_PARALLELISM="false",
                           HF_HOME=str(directory / "hf"), XDG_CACHE_HOME=str(directory / "cache"),
                           NUMBA_CACHE_DIR=str(directory / "numba"), TMPDIR=temporary)
        with (directory / "worker.log").open("w") as log:
            process = subprocess.Popen([str(ROOT / "runtime-v2/bin/python3"), "-u", str(SCRIPT),
                                        "serve", "--root", str(ROOT), "--model", "qwen_06"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                       text=True, env=environment)
            try:
                ready = json.loads(process.stdout.readline())
                assert ready.get("ready"), ready
                for iteration in range(12):
                    process.stdin.write(json.dumps(dict(path=str(sample), language="ru")) + "\n")
                    process.stdin.flush()
                    while True:
                        line = process.stdout.readline()
                        assert line, "Worker stopped before returning text"
                        response = json.loads(line)
                        assert "error" not in response, response
                        if "text" in response:
                            assert response["text"].strip()
                            break
                    memory = int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(process.pid)]))
                    rss.append(memory)
                    print(json.dumps(dict(iteration=iteration, rssKiB=memory)), flush=True)
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()
            assert process.returncode == 0, (directory / "worker.log").read_text()[-2000:]
    print(json.dumps(dict(workerExited=True, temporaryRemoved=not directory.exists(),
                          firstRSSMiB=round(rss[0] / 1024, 1), lastRSSMiB=round(rss[-1] / 1024, 1),
                          warmedRangeMiB=round((max(rss[3:]) - min(rss[3:])) / 1024, 1))))


if __name__ == "__main__":
    main()
