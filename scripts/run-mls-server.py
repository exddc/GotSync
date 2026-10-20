import asyncio
import signal
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from gotsync_server.mls import MLSDeliveryServer, MLSDeliveryStore


async def main() -> None:
    directory = Path(sys.argv[1])
    server = MLSDeliveryServer(MLSDeliveryStore(directory / "mls.sqlite3"))
    port = await server.start()
    try:
        (directory / "endpoint.tmp").write_text(f"http://127.0.0.1:{port}/v2/mls")
        (directory / "endpoint.tmp").replace(directory / "endpoint")
        stopped = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(sig, stopped.set)
        await stopped.wait()
    finally:
        await server.close()


asyncio.run(main())
