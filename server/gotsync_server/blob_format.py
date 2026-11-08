"""Ciphertext layout and object identity of encrypted blob parts (format GSB1)."""
from __future__ import annotations

import hashlib
import struct
from typing import NamedTuple

from .http import RequestError

PLAINTEXT_PART_BYTES = 524_288
TAG_BYTES = 16
PART_BYTES = PLAINTEXT_PART_BYTES + TAG_BYTES
MAX_PLAINTEXT_BYTES = 10_485_760
MAX_PARTS = 20
MAX_OBJECT_BYTES = MAX_PARTS * PART_BYTES
ID_BYTES = 32
OBJECT_PREFIX = b"GSB1-object"


class Layout(NamedTuple):
    parts: int
    last_part_bytes: int


def layout(length: object) -> Layout:
    if type(length) is not int or not 1 <= length <= MAX_OBJECT_BYTES:
        raise RequestError("invalid blob length")
    parts = -(-length // PART_BYTES)
    last = length - (parts - 1) * PART_BYTES
    if last <= TAG_BYTES:
        raise RequestError("invalid blob length")
    return Layout(parts, last)


def part_bytes(length: int, index: int) -> int:
    parts, last = layout(length)
    if type(index) is not int or not 0 <= index < parts:
        raise RequestError("invalid part index")
    return last if index == parts - 1 else PART_BYTES


def object_id(route: bytes, length: int, part_hashes: tuple[bytes, ...]) -> bytes:
    digest = hashlib.sha256(OBJECT_PREFIX)
    digest.update(route)
    digest.update(struct.pack(">QI", length, len(part_hashes)))
    for part_hash in part_hashes:
        digest.update(part_hash)
    return digest.digest()


def identifier(value: object, name: str) -> bytes:
    if type(value) is not bytes or len(value) != ID_BYTES:
        raise RequestError(f"invalid {name}")
    return value


class Manifest(NamedTuple):
    route: bytes
    object: bytes
    length: int
    part_hashes: tuple[bytes, ...]

    @classmethod
    def validated(cls, route: object, object_: object, length: object, part_hashes: object) -> Manifest:
        route = identifier(route, "route")
        object_ = identifier(object_, "object")
        parts, _ = layout(length)
        if type(part_hashes) not in (list, tuple) or len(part_hashes) != parts:
            raise RequestError("part count does not match the length")
        hashes = tuple(identifier(value, "part hash") for value in part_hashes)
        if object_id(route, length, hashes) != object_:
            raise RequestError("object does not match its manifest")
        return cls(route, object_, length, hashes)

    @property
    def parts(self) -> int:
        return len(self.part_hashes)

    def part_bytes(self, index: int) -> int:
        return part_bytes(self.length, index)
