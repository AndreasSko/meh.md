"""Bounded child execution with cancellation cleanup for owned CI processes."""
import os
from pathlib import Path
import signal
import subprocess


def terminate_process_group(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)


def run_logged(arguments, path, cwd=None, timeout=7200):
    arguments = list(map(str, arguments))
    print("Running:", " ".join(arguments), flush=True)
    with Path(path).open("w") as log:
        process = subprocess.Popen(arguments, cwd=cwd, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except BaseException:
            terminate_process_group(process)
            raise
    if status:
        raise subprocess.CalledProcessError(status, arguments)


def cancellation_handler(signum, frame):
    raise KeyboardInterrupt(f"Cancelled by signal {signum}")
