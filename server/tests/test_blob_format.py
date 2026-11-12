import hashlib
import json
from pathlib import Path

import pytest

from gotsync_server.blob_format import (
    MAX_OBJECT_BYTES, MAX_PARTS, OBJECT_PREFIX, PART_BYTES, TAG_BYTES, Manifest, layout, object_id, part_bytes,
)
from gotsync_server.http import RequestError

FIXTURE = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "blob-vectors-v1.json"
FIXTURE_SHA256 = "169df76ee3533ff94321e45c8331fb26c0ad89eb5062f2020cb66a5aab5df4c3"


@pytest.fixture(scope="module")
def vectors():
    data = FIXTURE.read_bytes()
    assert hashlib.sha256(data).hexdigest() == FIXTURE_SHA256
    return json.loads(data)


def test_constants_match_the_frozen_fixture(vectors):
    constants = vectors["constants"]
    assert constants["ciphertext_part"] == PART_BYTES
    assert constants["tag"] == TAG_BYTES
    assert constants["max_part_count"] == MAX_PARTS
    assert constants["max_ciphertext_length"] == MAX_OBJECT_BYTES
    assert bytes.fromhex(constants["object_prefix"]) == OBJECT_PREFIX


def test_accepted_vectors_validate_under_their_route_only(vectors):
    route, wrong_route = bytes.fromhex(vectors["route"]), bytes.fromhex(vectors["wrong_route"])
    for vector in vectors["accepted"]:
        length = vector["ciphertext_length"]
        hashes = [bytes.fromhex(value) for value in vector["part_hashes"]]
        wrong_hashes = [bytes.fromhex(value) for value in vector["wrong_route_part_hashes"]]
        assert layout(length) == (vector["part_count"], vector["last_part_length"])
        assert [part_bytes(length, index) for index in range(vector["part_count"])] == (
            [PART_BYTES] * (vector["part_count"] - 1) + [vector["last_part_length"]])
        manifest = Manifest.validated(route, bytes.fromhex(vector["object_id"]), length, hashes)
        assert manifest.parts == vector["part_count"]
        assert Manifest.validated(wrong_route, bytes.fromhex(vector["wrong_route_object_id"]), length, wrong_hashes)
        for mismatched in (
            (wrong_route, bytes.fromhex(vector["object_id"]), length, hashes),
            (route, bytes.fromhex(vector["wrong_route_object_id"]), length, hashes),
            (route, bytes.fromhex(vector["object_id"]), length, wrong_hashes),
        ):
            with pytest.raises(RequestError, match="object does not match"):
                Manifest.validated(*mismatched)
        with pytest.raises(RequestError):
            part_bytes(length, vector["part_count"])


def test_rejected_lengths_manifests_and_part_sizes(vectors):
    route = bytes.fromhex(vectors["route"])
    for entry in vectors["rejected_ciphertext_lengths"]:
        with pytest.raises(RequestError):
            layout(entry["ciphertext_length"])
    for plaintext in vectors["rejected_plaintext_lengths"]:
        parts = -(-plaintext // (PART_BYTES - TAG_BYTES)) or 1
        with pytest.raises(RequestError):
            layout(plaintext + TAG_BYTES * parts)
    for entry in vectors["rejected_manifests"]:
        hashes = [bytes(32)] * entry["part_count"]
        with pytest.raises(RequestError):
            Manifest.validated(route, object_id(route, entry["ciphertext_length"], tuple(hashes)),
                               entry["ciphertext_length"], hashes)
    for entry in vectors["rejected_part_lengths"]:
        assert part_bytes(entry["ciphertext_length"], entry["index"]) != entry["length"]


@pytest.mark.parametrize("length", [True, 17.0, "17", None, -1])
def test_lengths_must_be_plain_integers(length):
    with pytest.raises(RequestError):
        layout(length)


def test_identifiers_must_be_exact_bytes(vectors):
    vector = vectors["accepted"][0]
    route, object_ = bytes.fromhex(vectors["route"]), bytes.fromhex(vector["object_id"])
    hashes = [bytes.fromhex(value) for value in vector["part_hashes"]]
    for arguments in (
        (route[:31], object_, 17, hashes),
        (bytearray(route), object_, 17, hashes),
        (route, object_ + b"\0", 17, hashes),
        (route, object_, 17, [hashes[0][:31]]),
        (route, object_, 17, hashes * 2),
        (route, object_, 17, iter(hashes)),
    ):
        with pytest.raises(RequestError):
            Manifest.validated(*arguments)
