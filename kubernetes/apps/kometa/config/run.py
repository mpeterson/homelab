import re
import subprocess
import sys
from pathlib import Path


RECORD = re.compile(r"^\[[^\]]+\]\s+\S+\s+(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+(.*)")


def log_signature(path):
    if not path.exists():
        return None
    stat = path.stat()
    return stat.st_ino, stat.st_mtime_ns, stat.st_size


def check_log(path, libraries):
    messages = []
    errors = 0
    for line in path.read_text().splitlines():
        record = RECORD.match(line)
        if record:
            level, message = record.groups()
            errors += level in ("ERROR", "CRITICAL")
            messages.append(message.strip(" |=\r\n"))

    if errors:
        print(f"Kometa failed: {errors} application error/critical log records; see {path}", file=sys.stderr)
        return False
    if "Finished Run" not in messages:
        print("Kometa failed: run completion was not logged", file=sys.stderr)
        return False
    missing = [library for library in libraries if f"Finished {library} Library Overlays" not in messages]
    if missing:
        print(f"Kometa failed: overlay processing did not finish for {', '.join(missing)}", file=sys.stderr)
        return False
    return True


def run(command, log_path, libraries):
    previous = log_signature(log_path)
    result = subprocess.run(command, check=False)
    if result.returncode:
        print(f"Kometa failed: process exited with status {result.returncode}", file=sys.stderr)
        return result.returncode if result.returncode > 0 else 128 - result.returncode
    if log_signature(log_path) in (None, previous):
        print("Kometa failed: no fresh run log was written", file=sys.stderr)
        return 1
    return 0 if check_log(log_path, libraries) else 1


def main():
    from ruamel.yaml import YAML

    config_path = Path("/config/config.yml")
    config = YAML(typ="safe").load(config_path)
    libraries = list(config["libraries"])
    if not libraries:
        print("Kometa failed: no libraries are configured", file=sys.stderr)
        return 1
    Path("/config/assets").mkdir(exist_ok=True)
    return run(
        [sys.executable, "kometa.py", "--run", "--read-only-config", "--config", str(config_path), *sys.argv[1:]],
        Path("/config/logs/meta.log"),
        libraries,
    )


if __name__ == "__main__":
    sys.exit(main())
