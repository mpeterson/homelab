#!/usr/bin/env python3

import base64
import hashlib
import os
import stat
import tempfile
from pathlib import Path


CONFIG_PATH = Path("/config/qBittorrent/qBittorrent.conf")
ITERATIONS = 100_000
SAFE_SETTINGS = {
    "AuthSubnetWhitelist": "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16",
    "AuthSubnetWhitelistEnabled": "true",
    "HostHeaderValidation": "false",
    "LocalHostAuth": "false",
    "ServerDomains": "*",
    "UseUPnP": "false",
}


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"{name} must be set and non-empty")
    if any(character in value for character in ("\0", "\r", "\n")):
        raise ValueError(f"{name} contains an unsupported character")
    return value


def password_hash(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac(
        "sha512",
        password.encode(),
        salt,
        ITERATIONS,
        dklen=64,
    )
    encoded_salt = base64.b64encode(salt).decode("ascii")
    encoded_digest = base64.b64encode(digest).decode("ascii")
    return f"@ByteArray({encoded_salt}:{encoded_digest})"


def update_webui_section(content: str, settings: dict[str, str]) -> str:
    newline = "\r\n" if "\r\n" in content else "\n"
    lines = content.splitlines(keepends=True)
    output: list[str] = []
    found_section = False
    in_webui = False
    written: set[str] = set()

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_webui:
                if output and not output[-1].endswith(("\n", "\r")):
                    output[-1] += newline
                for key, value in settings.items():
                    if key not in written:
                        output.append(f"{key}={value}{newline}")
                        written.add(key)
            in_webui = stripped == "[WebUI]"
            found_section = found_section or in_webui
            output.append(line)
            continue

        if in_webui:
            key, separator, _ = stripped.partition("=")
            if separator and key in settings:
                if key not in written:
                    output.append(f"{key}={settings[key]}{newline}")
                    written.add(key)
                continue

        output.append(line)

    if in_webui:
        if output and not output[-1].endswith(("\n", "\r")):
            output[-1] += newline
        for key, value in settings.items():
            if key not in written:
                output.append(f"{key}={value}{newline}")
                written.add(key)

    if not found_section:
        if output and not output[-1].endswith(("\n", "\r")):
            output[-1] += newline
        if output and output[-1].strip():
            output.append(newline)
        output.append(f"[WebUI]{newline}")
        output.extend(f"{key}={value}{newline}" for key, value in settings.items())

    return "".join(output)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    temporary_path: str | None = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary_file:
            temporary_path = temporary_file.name
            os.fchmod(temporary_file.fileno(), existing_mode)
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())

        os.replace(temporary_path, path)
        temporary_path = None

        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_path is not None:
            Path(temporary_path).unlink(missing_ok=True)


def main() -> None:
    username = required_environment("QBT_USERNAME")
    password = required_environment("QBT_PASSWORD")
    settings = {
        "Username": username,
        "Password_PBKDF2": password_hash(password),
    } | SAFE_SETTINGS

    content = CONFIG_PATH.read_text(encoding="utf-8") if CONFIG_PATH.exists() else ""
    atomic_write(CONFIG_PATH, update_webui_section(content, settings))


if __name__ == "__main__":
    main()
