#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("repair-matrix-migrated-media-cache.py")
SPEC = importlib.util.spec_from_file_location("matrix_media_repair", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def assert_equal(actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


with tempfile.TemporaryDirectory() as directory:
    media_store = Path(directory)
    media_id = "AbCdEf0123"
    origin = "old.example"
    source = MODULE.local_media_path(media_store, media_id)
    destination = MODULE.remote_media_path(media_store, origin, media_id)
    source.parent.mkdir(parents=True)
    source.write_bytes(b"media")

    assert_equal(
        source.relative_to(media_store).as_posix(),
        "local_content/Ab/Cd/Ef0123",
    )
    assert_equal(
        destination.relative_to(media_store).as_posix(),
        "remote_content/old.example/Ab/Cd/Ef0123",
    )
    assert_equal(MODULE.ensure_hardlink(source, destination, False), "planned")
    assert not destination.exists()
    assert_equal(MODULE.ensure_hardlink(source, destination, True), "created")
    assert os.path.samefile(source, destination)
    assert_equal(MODULE.ensure_hardlink(source, destination, True), "existing")

    thumbnail = MODULE.ThumbnailRecord(
        media_id=media_id,
        width=320,
        height=240,
        media_type="image/jpeg",
        method="scale",
        length=5,
    )
    thumbnail_source = MODULE.local_thumbnail_path(media_store, thumbnail)
    thumbnail_destination = MODULE.remote_thumbnail_path(
        media_store, origin, thumbnail
    )
    assert_equal(
        thumbnail_source.relative_to(media_store).as_posix(),
        "local_thumbnails/Ab/Cd/Ef0123/320-240-image-jpeg-scale",
    )
    assert_equal(
        thumbnail_destination.relative_to(media_store).as_posix(),
        "remote_thumbnail/old.example/Ab/Cd/Ef0123/320-240-image-jpeg-scale",
    )

    conflict_source = MODULE.local_media_path(media_store, "ZzYyConflict")
    conflict_destination = MODULE.remote_media_path(
        media_store, origin, "ZzYyConflict"
    )
    conflict_source.parent.mkdir(parents=True, exist_ok=True)
    conflict_destination.parent.mkdir(parents=True, exist_ok=True)
    conflict_source.write_bytes(b"source")
    conflict_destination.write_bytes(b"different")
    assert_equal(
        MODULE.ensure_hardlink(
            conflict_source, conflict_destination, True
        ),
        "conflict",
    )

print("Matrix migrated-media cache checks passed.")
