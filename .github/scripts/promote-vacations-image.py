#!/usr/bin/env python3

import re
import sys
from pathlib import Path


SOURCE_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
VALUES_PATH = Path("kubernetes/apps/vacations/values.yaml")
APP_PATH = Path("kubernetes/apps/vacations/app.yaml")
IMAGE = "ghcr.io/mpeterson/vacations-site"


def replace_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"expected exactly one {label}, found {count}")
    return updated


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: promote-vacations-image.py <source-sha> <digest>")

    source_sha, digest = sys.argv[1:]
    if not SOURCE_PATTERN.fullmatch(source_sha):
        raise SystemExit("source SHA must be exactly 40 lowercase hexadecimal characters")
    if not DIGEST_PATTERN.fullmatch(digest):
        raise SystemExit("digest must be sha256 followed by 64 lowercase hexadecimal characters")

    image_ref = f"{IMAGE}:sha-{source_sha}@{digest}"
    values = VALUES_PATH.read_text()

    if "enabled: &workloadsEnabled false" in values:
        values = values.replace(
            "enabled: &workloadsEnabled false",
            "enabled: &workloadsEnabled true",
            1,
        )
    elif "enabled: &workloadsEnabled true" not in values:
        raise RuntimeError("vacations workload bootstrap flag is missing")

    if f"          repository: {IMAGE}" in values:
        values = replace_once(
            values,
            rf"^(\s+tag:\s+)sha-[0-9a-f]{{40}}@sha256:[0-9a-f]{{64}}$",
            rf"\g<1>sha-{source_sha}@{digest}",
            "vacations image tag",
        )
    else:
        marker = "        # Promotion automation manages the digest-pinned image.\n"
        if values.count(marker) != 1:
            raise RuntimeError("vacations image insertion marker is missing or ambiguous")
        values = values.replace(
            marker,
            marker
            + "        image:\n"
            + f"          repository: {IMAGE}\n"
            + f"          tag: sha-{source_sha}@{digest}\n",
            1,
        )

    app = APP_PATH.read_text()
    app = replace_once(
        app,
        r"^(\s+value: )(?:pending-first-publish|[0-9a-f]{40})$",
        rf"\g<1>{source_sha}",
        "source SHA value",
    )
    app = replace_once(
        app,
        rf"^(\s+value: ){re.escape(IMAGE)}:(?:pending-first-publish|sha-[0-9a-f]{{40}}@sha256:[0-9a-f]{{64}})$",
        rf"\g<1>{image_ref}",
        "image info value",
    )

    VALUES_PATH.write_text(values)
    APP_PATH.write_text(app)


if __name__ == "__main__":
    main()
