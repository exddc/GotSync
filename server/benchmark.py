from __future__ import annotations

import argparse
import asyncio
import base64
import json
import math
import os
import statistics
import time

from websockets.asyncio.client import connect


def registration(route: bytes) -> str:
    encoded = base64.urlsafe_b64encode(route).rstrip(b"=").decode("ascii")
    return json.dumps(
        {"route": encoded, "type": "register", "version": 1},
        separators=(",", ":"),
        sort_keys=True,
    )


async def run(url: str, iterations: int, payload_bytes: int) -> dict[str, float | int]:
    route = os.urandom(32)
    payload = os.urandom(payload_bytes)
    async with (
        connect(url, compression=None, max_size=512 * 1024) as first,
        connect(url, compression=None, max_size=512 * 1024) as second,
    ):
        await first.send(registration(route))
        await second.send(registration(route))
        await asyncio.gather(first.recv(), second.recv())

        async def echo() -> None:
            for _ in range(iterations + 20):
                await second.send(await second.recv())

        echo_task = asyncio.create_task(echo())
        samples: list[float] = []
        for index in range(iterations + 20):
            started = time.perf_counter_ns()
            await first.send(payload)
            response = await first.recv()
            elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
            if response != payload:
                raise RuntimeError("relay altered the benchmark payload")
            if index >= 20:
                samples.append(elapsed_ms)
        await echo_task

    ordered = sorted(samples)
    return {
        "iterations": iterations,
        "payload_bytes": payload_bytes,
        "p50_ms": round(statistics.median(ordered), 3),
        "p95_ms": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 3),
        "max_ms": round(max(ordered), 3),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark the volatile relay")
    parser.add_argument("--url", default="ws://127.0.0.1:8765/v1")
    parser.add_argument("--iterations", type=int, default=500)
    parser.add_argument("--payload-bytes", type=int, default=256)
    arguments = parser.parse_args()
    if arguments.iterations <= 0 or arguments.payload_bytes <= 0:
        parser.error("iterations and payload size must be positive")
    print(
        json.dumps(
            asyncio.run(
                run(
                    arguments.url,
                    arguments.iterations,
                    arguments.payload_bytes,
                )
            ),
            separators=(",", ":"),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
