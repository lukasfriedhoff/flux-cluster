#!/usr/bin/env python3
"""Expose migrated local Synapse media under its retained MXC origin."""

from __future__ import annotations

import argparse
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class MediaRecord:
    media_id: str
    media_type: str
    media_length: int
    created_ts: int
    upload_name: str | None
    last_access_ts: int | None
    authenticated: bool
    sha256: str | None


@dataclass(frozen=True)
class ThumbnailRecord:
    media_id: str
    width: int
    height: int
    media_type: str
    method: str
    length: int


def media_components(media_id: str) -> tuple[str, str, str]:
    if len(media_id) < 5 or not re.fullmatch(r"[A-Za-z0-9_-]+", media_id):
        raise ValueError("invalid Synapse media ID")
    return media_id[:2], media_id[2:4], media_id[4:]


def local_media_path(media_store: Path, media_id: str) -> Path:
    return media_store.joinpath("local_content", *media_components(media_id))


def remote_media_path(media_store: Path, origin: str, media_id: str) -> Path:
    return media_store.joinpath(
        "remote_content", origin, *media_components(media_id)
    )


def thumbnail_filename(
    width: int, height: int, media_type: str, method: str
) -> str:
    top_level_type, sub_type = media_type.split("/", maxsplit=1)
    return f"{width}-{height}-{top_level_type}-{sub_type}-{method}"


def local_thumbnail_path(
    media_store: Path, thumbnail: ThumbnailRecord
) -> Path:
    return media_store.joinpath(
        "local_thumbnails",
        *media_components(thumbnail.media_id),
        thumbnail_filename(
            thumbnail.width,
            thumbnail.height,
            thumbnail.media_type,
            thumbnail.method,
        ),
    )


def remote_thumbnail_path(
    media_store: Path, origin: str, thumbnail: ThumbnailRecord
) -> Path:
    return media_store.joinpath(
        "remote_thumbnail",
        origin,
        *media_components(thumbnail.media_id),
        thumbnail_filename(
            thumbnail.width,
            thumbnail.height,
            thumbnail.media_type,
            thumbnail.method,
        ),
    )


def ensure_hardlink(source: Path, destination: Path, apply: bool) -> str:
    if not source.is_file():
        return "missing"
    if destination.exists():
        if destination.is_file() and os.path.samefile(source, destination):
            return "existing"
        return "conflict"
    if not apply:
        return "planned"
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except FileExistsError:
        if destination.is_file() and os.path.samefile(source, destination):
            return "existing"
        return "conflict"
    return "created"


def database_args(config_path: Path) -> dict[str, Any]:
    import yaml

    with config_path.open(encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    database = config.get("database")
    if not isinstance(database, dict) or database.get("name") != "psycopg2":
        raise RuntimeError("Synapse psycopg2 database config was not found")
    args = database.get("args")
    if not isinstance(args, dict):
        raise RuntimeError("Synapse database args were not found")
    return {
        key: value
        for key, value in args.items()
        if key not in {"cp_min", "cp_max", "cp_reconnect", "cp_noisy"}
    }


def fetch_media(cursor: Any, origin: str) -> list[MediaRecord]:
    pattern = rf"mxc://{re.escape(origin)}/([A-Za-z0-9_-]+)"
    cursor.execute(
        """
        WITH referenced_media AS (
          SELECT DISTINCT match[1] AS media_id
          FROM event_json AS event
          CROSS JOIN LATERAL regexp_matches(event.json, %s, 'g') AS match
        )
        SELECT
          local.media_id,
          local.media_type,
          local.media_length,
          local.created_ts,
          local.upload_name,
          local.last_access_ts,
          local.authenticated,
          local.sha256
        FROM referenced_media
        JOIN local_media_repository AS local USING (media_id)
        ORDER BY local.media_id
        """,
        (pattern,),
    )
    return [MediaRecord(*row) for row in cursor.fetchall()]


def fetch_thumbnails(cursor: Any, origin: str) -> list[ThumbnailRecord]:
    pattern = rf"mxc://{re.escape(origin)}/([A-Za-z0-9_-]+)"
    cursor.execute(
        """
        WITH referenced_media AS (
          SELECT DISTINCT match[1] AS media_id
          FROM event_json AS event
          CROSS JOIN LATERAL regexp_matches(event.json, %s, 'g') AS match
        )
        SELECT
          thumbnail.media_id,
          thumbnail.thumbnail_width,
          thumbnail.thumbnail_height,
          thumbnail.thumbnail_type,
          thumbnail.thumbnail_method,
          thumbnail.thumbnail_length
        FROM referenced_media
        JOIN local_media_repository_thumbnails AS thumbnail USING (media_id)
        ORDER BY
          thumbnail.media_id,
          thumbnail.thumbnail_width,
          thumbnail.thumbnail_height,
          thumbnail.thumbnail_type,
          thumbnail.thumbnail_method
        """,
        (pattern,),
    )
    return [ThumbnailRecord(*row) for row in cursor.fetchall()]


def link_records(
    records: Iterable[MediaRecord],
    media_store: Path,
    origin: str,
    apply: bool,
) -> tuple[list[MediaRecord], dict[str, int]]:
    usable: list[MediaRecord] = []
    counts: dict[str, int] = {}
    for record in records:
        result = ensure_hardlink(
            local_media_path(media_store, record.media_id),
            remote_media_path(media_store, origin, record.media_id),
            apply,
        )
        counts[result] = counts.get(result, 0) + 1
        if result not in {"missing", "conflict"}:
            usable.append(record)
    return usable, counts


def link_thumbnails(
    records: Iterable[ThumbnailRecord],
    media_store: Path,
    origin: str,
    apply: bool,
) -> tuple[list[ThumbnailRecord], dict[str, int]]:
    usable: list[ThumbnailRecord] = []
    counts: dict[str, int] = {}
    for record in records:
        result = ensure_hardlink(
            local_thumbnail_path(media_store, record),
            remote_thumbnail_path(media_store, origin, record),
            apply,
        )
        counts[result] = counts.get(result, 0) + 1
        if result not in {"missing", "conflict"}:
            usable.append(record)
    return usable, counts


def store_media(
    cursor: Any, origin: str, records: Iterable[MediaRecord], page_size: int
) -> None:
    from psycopg2.extras import execute_values

    values = [
        (
            origin,
            record.media_id,
            record.media_type,
            record.created_ts,
            record.upload_name,
            record.media_length,
            record.media_id,
            record.last_access_ts or record.created_ts,
            record.authenticated,
            record.sha256,
        )
        for record in records
    ]
    if not values:
        return
    execute_values(
        cursor,
        """
        INSERT INTO remote_media_cache (
          media_origin,
          media_id,
          media_type,
          created_ts,
          upload_name,
          media_length,
          filesystem_id,
          last_access_ts,
          authenticated,
          sha256
        ) VALUES %s
        ON CONFLICT (media_origin, media_id) DO UPDATE SET
          media_type = EXCLUDED.media_type,
          created_ts = EXCLUDED.created_ts,
          upload_name = EXCLUDED.upload_name,
          media_length = EXCLUDED.media_length,
          filesystem_id = EXCLUDED.filesystem_id,
          last_access_ts = EXCLUDED.last_access_ts,
          authenticated = EXCLUDED.authenticated,
          sha256 = EXCLUDED.sha256
        """,
        values,
        page_size=page_size,
    )


def store_thumbnails(
    cursor: Any,
    origin: str,
    records: Iterable[ThumbnailRecord],
    page_size: int,
) -> None:
    from psycopg2.extras import execute_values

    values = [
        (
            origin,
            record.media_id,
            record.width,
            record.height,
            record.method,
            record.media_type,
            record.length,
            record.media_id,
        )
        for record in records
    ]
    if not values:
        return
    execute_values(
        cursor,
        """
        INSERT INTO remote_media_cache_thumbnails (
          media_origin,
          media_id,
          thumbnail_width,
          thumbnail_height,
          thumbnail_method,
          thumbnail_type,
          thumbnail_length,
          filesystem_id
        ) VALUES %s
        ON CONFLICT (
          media_origin,
          media_id,
          thumbnail_width,
          thumbnail_height,
          thumbnail_type,
          thumbnail_method
        ) DO UPDATE SET
          thumbnail_length = EXCLUDED.thumbnail_length,
          filesystem_id = EXCLUDED.filesystem_id
        """,
        values,
        page_size=page_size,
    )


def print_counts(prefix: str, counts: dict[str, int]) -> None:
    for status in ("planned", "created", "existing", "missing", "conflict"):
        print(f"{prefix}_{status}={counts.get(status, 0)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("/config/server.yaml"))
    parser.add_argument("--media-store", type=Path, default=Path("/media_store"))
    parser.add_argument("--origin", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--batch-size", type=int, default=500)
    args = parser.parse_args()

    if args.batch_size < 1:
        parser.error("--batch-size must be positive")
    if "/" in args.origin or not args.origin:
        parser.error("--origin must be a Matrix server name")
    if not args.media_store.is_dir():
        parser.error("--media-store must exist")

    import psycopg2

    connection = psycopg2.connect(**database_args(args.config))
    try:
        with connection.cursor() as cursor:
            media = fetch_media(cursor, args.origin)
            thumbnails = fetch_thumbnails(cursor, args.origin)

        usable_media, media_counts = link_records(
            media, args.media_store, args.origin, args.apply
        )
        usable_thumbnails, thumbnail_counts = link_thumbnails(
            thumbnails, args.media_store, args.origin, args.apply
        )

        print(f"referenced_media={len(media)}")
        print(f"referenced_thumbnails={len(thumbnails)}")
        print_counts("media", media_counts)
        print_counts("thumbnail", thumbnail_counts)

        if media_counts.get("missing", 0) or media_counts.get("conflict", 0):
            print("database_updated=no")
            return 1
        if thumbnail_counts.get("missing", 0) or thumbnail_counts.get("conflict", 0):
            print("database_updated=no")
            return 1
        if not args.apply:
            print("database_updated=no")
            return 0

        with connection:
            with connection.cursor() as cursor:
                store_media(cursor, args.origin, usable_media, args.batch_size)
                store_thumbnails(
                    cursor,
                    args.origin,
                    usable_thumbnails,
                    args.batch_size,
                )
        print("database_updated=yes")
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
