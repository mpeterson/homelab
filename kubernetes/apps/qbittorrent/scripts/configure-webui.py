#!/usr/bin/env python3

import base64
import configparser
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
from pathlib import Path
from urllib import error, parse, request


CONFIG_PATH = Path("/config/qBittorrent/qBittorrent.conf")
CATEGORIES_PATH = Path("/config/qBittorrent/categories.json")
DEFAULT_SAVE_PATH = Path("/data/downloads/torrents")
DEFAULT_TEMP_PATH = Path("/data/incomplete-downloads/torrents")
QBITTORRENT_API = "http://127.0.0.1/api/v2"
STALE_SAVE_PATH = Path("/config/Downloads")
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


def resolve_download_path(configured_path: str) -> Path:
    path = Path(configured_path)
    path = path if path.is_absolute() else DEFAULT_SAVE_PATH / path
    path = path.resolve()
    path.relative_to(DEFAULT_SAVE_PATH.resolve())
    return path


def configure() -> None:
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
    if CATEGORIES_PATH.exists():
        categories = json.loads(CATEGORIES_PATH.read_text(encoding="utf-8"))
        for options in categories.values():
            resolve_download_path(options.get("save_path", "")).mkdir(
                parents=True,
                exist_ok=True,
            )

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


def api_request(endpoint: str, data: dict[str, str] | None = None) -> object:
    encoded_data = parse.urlencode(data).encode() if data is not None else None
    with request.urlopen(
        request.Request(f"{QBITTORRENT_API}/{endpoint}", data=encoded_data),
        timeout=5,
    ) as response:
        body = response.read()
    return json.loads(body) if body else None


def wait_for_api() -> None:
    for _ in range(60):
        try:
            api_request("app/version")
            return
        except (error.URLError, TimeoutError):
            time.sleep(1)
    raise RuntimeError("qBittorrent API did not become ready within 60 seconds")


def category_path(category: str, categories: dict[str, dict[str, str]]) -> Path:
    return resolve_download_path(categories.get(category, {}).get("savePath", ""))


def repair_download_paths() -> None:
    wait_for_api()
    categories = api_request("torrents/categories")
    torrents = api_request("torrents/info?filter=all")
    if not isinstance(categories, dict) or not isinstance(torrents, list):
        raise RuntimeError("qBittorrent API returned an unexpected response")

    for torrent in torrents:
        save_path = Path(torrent.get("save_path", ""))
        try:
            save_path.relative_to(STALE_SAVE_PATH)
        except ValueError:
            continue

        path = category_path(torrent.get("category", ""), categories)
        path.mkdir(parents=True, exist_ok=True)
        api_request(
            "torrents/setLocation",
            {"hashes": torrent["hash"], "location": str(path)},
        )


def main() -> None:
    if len(sys.argv) == 1:
        configure()
        return
    if sys.argv[1:] == ["repair-download-paths"]:
        repair_download_paths()
        return
    raise ValueError(f"unsupported arguments: {sys.argv[1:]}")


if __name__ == "__main__":
    main()
