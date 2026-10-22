#!/usr/bin/env python3

import base64
import configparser
import hashlib
import os
import stat
import tempfile
from pathlib import Path


CONFIG_PATH = Path("/config/qBittorrent/qBittorrent.conf")
DEFAULT_SAVE_PATH = Path("/data/downloads/torrents")
DEFAULT_TEMP_PATH = Path("/data/incomplete-downloads/torrents")
CATEGORY_PATHS = ("movies", "tv")
BITTORRENT_SETTINGS = {
    "Session\\DefaultSavePath": str(DEFAULT_SAVE_PATH),
    "Session\\TempPath": str(DEFAULT_TEMP_PATH),
    "Session\\TempPathEnabled": "true",
    "Session\\UseCategoryPathsInManualMode": "true",
}
WEBUI_SETTINGS = {
    "AuthSubnetWhitelist": "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16",
    "AuthSubnetWhitelistEnabled": "true",
    "HostHeaderValidation": "false",
    "LocalHostAuth": "false",
    "ServerDomains": "*",
    "UseUPnP": "false",
}


def get_credential(name: str) -> str:
    value = os.environ.get(name, "")
    if not value or any(character in value for character in "\0\r\n"):
        raise ValueError(f"{name} must be a non-empty, single-line value")
    return value


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac(
        "sha512", password.encode(), salt, 100_000, dklen=64
    )
    return "@ByteArray({}:{})".format(
        base64.b64encode(salt).decode(),
        base64.b64encode(digest).decode(),
    )


def main() -> None:
    config = configparser.RawConfigParser()
    config.optionxform = str
    if CONFIG_PATH.exists():
        config.read(CONFIG_PATH, encoding="utf-8")
    else:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)

    settings_by_section = {
        "BitTorrent": BITTORRENT_SETTINGS,
        "WebUI": {
            "Username": get_credential("QBT_USERNAME"),
            "Password_PBKDF2": hash_password(get_credential("QBT_PASSWORD")),
        }
        | WEBUI_SETTINGS,
    }
    for section, settings in settings_by_section.items():
        if not config.has_section(section):
            config.add_section(section)
        for key, value in settings.items():
            config.set(section, key, value)

    DEFAULT_SAVE_PATH.mkdir(parents=True, exist_ok=True)
    DEFAULT_TEMP_PATH.mkdir(parents=True, exist_ok=True)
    for category in CATEGORY_PATHS:
        (DEFAULT_SAVE_PATH / category).mkdir(parents=True, exist_ok=True)

    mode = stat.S_IMODE(CONFIG_PATH.stat().st_mode) if CONFIG_PATH.exists() else 0o600
    descriptor, temporary_path = tempfile.mkstemp(
        dir=CONFIG_PATH.parent,
        prefix=f".{CONFIG_PATH.name}.",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
            os.fchmod(temporary_file.fileno(), mode)
            config.write(temporary_file, space_around_delimiters=False)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, CONFIG_PATH)
        temporary_path = ""
    finally:
        if temporary_path:
            Path(temporary_path).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
