#!/usr/bin/env python3
"""Build and verify canonical, link-free Chatwoot storage artifacts."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tarfile

MAX_FILES = 2_000_000
MAX_PATH_BYTES = 4096
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024


class ArtifactError(Exception):
    pass


def canonical_relative(value: str) -> str:
    candidate = value.removeprefix("./")
    path = PurePosixPath(candidate)
    if (
        not candidate
        or candidate.startswith("/")
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in path.parts)
        or any(ord(char) < 32 or ord(char) == 127 for char in candidate)
        or len(candidate.encode("utf-8")) > MAX_PATH_BYTES
    ):
        raise ArtifactError("unsafe storage path")
    return path.as_posix()


def digest_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_BYTES):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def collect_manifest(root: Path) -> bytes:
    root = root.resolve(strict=True)
    rows: list[tuple[bytes, str, int, str]] = []
    total_bytes = 0
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in [*directory_names, *file_names]:
            path = directory_path / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ArtifactError("storage contains a link or special entry")
        for name in file_names:
            path = directory_path / name
            relative = canonical_relative(path.relative_to(root).as_posix())
            size, digest = digest_file(path)
            total_bytes += size
            if total_bytes > MAX_TOTAL_BYTES:
                raise ArtifactError("storage exceeds the artifact byte ceiling")
            rows.append((relative.encode("utf-8"), relative, size, digest))
            if len(rows) > MAX_FILES:
                raise ArtifactError("storage exceeds the artifact file ceiling")
    rows.sort(key=lambda row: row[0])
    if not rows:
        raise ArtifactError("storage manifest is empty")
    return "".join(f"{relative}\t{size}\t{digest}\n" for _, relative, size, digest in rows).encode()


def write_manifest(root: Path, output: Path) -> None:
    output.write_bytes(collect_manifest(root))


def validate_members(archive: tarfile.TarFile) -> list[tuple[tarfile.TarInfo, str]]:
    accepted: list[tuple[tarfile.TarInfo, str]] = []
    names: set[str] = set()
    total_bytes = 0
    for member in archive:
        raw_name = member.name
        if raw_name in (".", "./"):
            if not member.isdir():
                raise ArtifactError("invalid archive root")
            continue
        relative = canonical_relative(raw_name)
        if relative in names:
            raise ArtifactError("duplicate archive path")
        names.add(relative)
        if not (member.isdir() or member.isfile()):
            raise ArtifactError("archive contains a link or special entry")
        if member.isfile():
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_BYTES:
                raise ArtifactError("archive exceeds the byte ceiling")
        accepted.append((member, relative))
        if len(accepted) > MAX_FILES * 2:
            raise ArtifactError("archive exceeds the entry ceiling")
    return accepted


def extract_verified(archive_path: Path, destination: Path) -> None:
    if destination.exists() and any(destination.iterdir()):
        raise ArtifactError("verification destination is not empty")
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tarfile.open(archive_path, mode="r:*") as archive:
        members = validate_members(archive)
        for member, relative in members:
            target = destination / relative
            resolved_parent = target.parent.resolve(strict=False)
            if destination.resolve() not in (resolved_parent, *resolved_parent.parents):
                raise ArtifactError("archive extraction escaped its root")
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ArtifactError("archive file has no payload")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source, output, length=CHUNK_BYTES)
                output.flush()
                os.fsync(output.fileno())


def verify_archive(archive_path: Path, expected_manifest_path: Path, scratch: Path) -> None:
    extract_verified(archive_path, scratch)
    observed = collect_manifest(scratch)
    expected = expected_manifest_path.read_bytes()
    if observed != expected:
        raise ArtifactError("extracted storage manifest differs from the source")


def fsync_path(path: Path) -> None:
    flags = os.O_RDONLY
    if path.is_dir():
        flags |= getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("root", type=Path)
    manifest.add_argument("output", type=Path)
    verify = subparsers.add_parser("verify-archive")
    verify.add_argument("archive", type=Path)
    verify.add_argument("manifest", type=Path)
    verify.add_argument("scratch", type=Path)
    fsync = subparsers.add_parser("fsync")
    fsync.add_argument("path", type=Path)
    arguments = parser.parse_args()

    if arguments.command == "manifest":
        write_manifest(arguments.root, arguments.output)
    elif arguments.command == "verify-archive":
        verify_archive(arguments.archive, arguments.manifest, arguments.scratch)
    else:
        fsync_path(arguments.path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ArtifactError, OSError, tarfile.TarError, UnicodeError) as error:
        print(f"fbig storage artifact error: {error}", file=sys.stderr)
        raise SystemExit(1)
