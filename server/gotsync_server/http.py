from __future__ import annotations

import asyncio
import json
from typing import Any

from .mailbox import MailboxError, MailboxHeadersTooLargeError, MailboxRequestTooLargeError

MAX_HTTP_HEADER_BYTES = 8192


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
        raise MailboxError("request timed out") from error
    except asyncio.IncompleteReadError as error:
        raise MailboxError("incomplete request") from error
    except asyncio.LimitOverrunError as error:
        raise MailboxHeadersTooLargeError("headers are too large") from error
    if len(raw_headers) > MAX_HTTP_HEADER_BYTES:
        raise MailboxHeadersTooLargeError("headers are too large")

    lines = raw_headers[:-4].split(b"\r\n")
    try:
        request_line = lines[0].decode("ascii")
        method, target, version = request_line.split(" ")
    except (UnicodeDecodeError, ValueError) as error:
        raise MailboxError("invalid request line") from error
    if version != "HTTP/1.1" or not target.startswith("/"):
        raise MailboxError("invalid request line")
    if "?" in target or "#" in target:
        raise MailboxError("mailbox endpoint cannot contain a query")

    headers: dict[str, str] = {}
    valid_header_name_bytes = frozenset(
        b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    for raw_line in lines[1:]:
        if b":" not in raw_line:
            raise MailboxError("invalid header")
        raw_name, raw_value = raw_line.split(b":", 1)
        if not raw_name or any(
            byte not in valid_header_name_bytes for byte in raw_name
        ):
            raise MailboxError("invalid header")
        try:
            name = raw_name.decode("ascii").lower()
            value = raw_value.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise MailboxError("invalid header") from error
        if name in headers:
            raise MailboxError("duplicate or invalid header")
        headers[name] = value

    if "transfer-encoding" in headers:
        raise MailboxError("transfer encoding is unsupported")
    return method, target, headers


async def read_http_body(
    reader: asyncio.StreamReader, headers: dict[str, str], *, maximum_body_bytes: int,
) -> bytes:
    raw_content_length = headers.get("content-length")
    if raw_content_length is None or not raw_content_length.isdigit():
        raise MailboxError("valid content length is required")
    if len(raw_content_length) > 10:
        raise MailboxRequestTooLargeError("request body is too large")
    content_length = int(raw_content_length)
    if content_length > maximum_body_bytes:
        raise MailboxRequestTooLargeError("request body is too large")
    try:
        body = await asyncio.wait_for(
            reader.readexactly(content_length),
            timeout=2,
        )
    except TimeoutError as error:
        raise MailboxError("request body timed out") from error
    except asyncio.IncompleteReadError as error:
        raise MailboxError("incomplete request body") from error
    return body


def parse_mailbox_json(body: bytes) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise MailboxError("JSON contains duplicate fields")
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
        raise MailboxError("request body is not valid JSON") from error
    if not isinstance(document, dict):
        raise MailboxError("request body must be an object")
    return document


async def write_http_response(
    writer: asyncio.StreamWriter, status: int, document: dict[str, Any]
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
    headers = (
        f"HTTP/1.1 {status} {reasons[status]}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(headers + body)
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
