from __future__ import annotations

import asyncio
import base64
import json
from collections.abc import Mapping
from typing import Any

MAX_HTTP_HEADER_BYTES = 8192


class RequestError(ValueError):
    code = "invalidRequest"
    status = 400


class RequestTooLargeError(RequestError):
    code = "requestTooLarge"
    status = 413


class HeadersTooLargeError(RequestError):
    code = "headersTooLarge"
    status = 431


def encode_base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def decode_canonical_base64url(
    value: object,
    *,
    field: str,
    exact_bytes: int | None = None,
    maximum_bytes: int | None = None,
) -> bytes:
    if not isinstance(value, str):
        raise RequestError(f"{field} must be a base64url string")
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as error:
        raise RequestError(f"{field} is not canonical base64url") from error
    if b"=" in encoded:
        raise RequestError(f"{field} is not canonical base64url")
    padding = b"=" * ((4 - len(encoded) % 4) % 4)
    try:
        decoded = base64.b64decode(
            encoded + padding,
            altchars=b"-_",
            validate=True,
        )
    except ValueError as error:
        raise RequestError(f"{field} is not canonical base64url") from error
    if base64.urlsafe_b64encode(decoded).rstrip(b"=") != encoded:
        raise RequestError(f"{field} is not canonical base64url")
    if exact_bytes is not None and len(decoded) != exact_bytes:
        raise RequestError(f"{field} has the wrong length")
    if maximum_bytes is not None and len(decoded) > maximum_bytes:
        raise RequestError(f"{field} is too large")
    return decoded


async def read_http_json_request(
    reader: asyncio.StreamReader,
    *,
    maximum_body_bytes: int,
) -> tuple[str, str, dict[str, str], bytes]:
    method, target, headers = await read_http_head(reader)
    body = await read_http_body(reader, headers, maximum_body_bytes=maximum_body_bytes)
    return method, target, headers, body


async def read_http_head(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str]]:
    try:
        raw_headers = await asyncio.wait_for(
            reader.readuntil(b"\r\n\r\n"),
            timeout=2,
        )
    except TimeoutError as error:
        raise RequestError("request timed out") from error
    except asyncio.IncompleteReadError as error:
        raise RequestError("incomplete request") from error
    except asyncio.LimitOverrunError as error:
        raise HeadersTooLargeError("headers are too large") from error
    if len(raw_headers) > MAX_HTTP_HEADER_BYTES:
        raise HeadersTooLargeError("headers are too large")

    lines = raw_headers[:-4].split(b"\r\n")
    try:
        request_line = lines[0].decode("ascii")
        method, target, version = request_line.split(" ")
    except (UnicodeDecodeError, ValueError) as error:
        raise RequestError("invalid request line") from error
    if version != "HTTP/1.1" or not target.startswith("/"):
        raise RequestError("invalid request line")
    if "?" in target or "#" in target:
        raise RequestError("endpoint cannot contain a query")

    headers: dict[str, str] = {}
    valid_header_name_bytes = frozenset(
        b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    for raw_line in lines[1:]:
        if b":" not in raw_line:
            raise RequestError("invalid header")
        raw_name, raw_value = raw_line.split(b":", 1)
        if not raw_name or any(
            byte not in valid_header_name_bytes for byte in raw_name
        ):
            raise RequestError("invalid header")
        try:
            name = raw_name.decode("ascii").lower()
            value = raw_value.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise RequestError("invalid header") from error
        if name in headers:
            raise RequestError("duplicate or invalid header")
        headers[name] = value

    if "transfer-encoding" in headers:
        raise RequestError("transfer encoding is unsupported")
    return method, target, headers


async def read_http_body(
    reader: asyncio.StreamReader, headers: dict[str, str], *, maximum_body_bytes: int,
) -> bytes:
    raw_content_length = headers.get("content-length")
    if raw_content_length is None or not raw_content_length.isdigit():
        raise RequestError("valid content length is required")
    if len(raw_content_length) > 10:
        raise RequestTooLargeError("request body is too large")
    content_length = int(raw_content_length)
    if content_length > maximum_body_bytes:
        raise RequestTooLargeError("request body is too large")
    try:
        body = await asyncio.wait_for(
            reader.readexactly(content_length),
            timeout=2,
        )
    except TimeoutError as error:
        raise RequestError("request body timed out") from error
    except asyncio.IncompleteReadError as error:
        raise RequestError("incomplete request body") from error
    return body


def parse_json_object(body: bytes) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise RequestError("JSON contains duplicate fields")
            result[key] = value
        return result

    try:
        document = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=unique_object,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        RecursionError,
        ValueError,
    ) as error:
        raise RequestError("request body is not valid JSON") from error
    if not isinstance(document, dict):
        raise RequestError("request body must be an object")
    return document


async def write_http_response(
    writer: asyncio.StreamWriter,
    status: int,
    document: dict[str, Any],
    headers: Mapping[str, str] | None = None,
) -> None:
    reasons = {
        200: "OK",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        409: "Conflict",
        413: "Content Too Large",
        429: "Too Many Requests",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        503: "Service Unavailable",
    }
    body = encode_json_document(document)
    extra = "".join(f"{name}: {value}\r\n" for name, value in (headers or {}).items())
    head = (
        f"HTTP/1.1 {status} {reasons[status]}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        f"{extra}"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(head + body)
    try:
        await writer.drain()
    except ConnectionError:
        pass


def encode_json_document(document: dict[str, Any]) -> bytes:
    return json.dumps(
        document,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
