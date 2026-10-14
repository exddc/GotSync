import asyncio
import json
import signal
import sys
from pathlib import Path
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from gotsync_server.server import RelayServer


async def main() -> None:
    directory = Path(sys.argv[1])
    server = RelayServer(port=0, mailbox_port=0, metrics_port=0, mailbox_database_path=directory / "mailbox.sqlite3")
    await server.start()
    try:
        def check_readiness() -> None:
            with urlopen(f"http://127.0.0.1:{server.bound_metrics_port}/readyz", timeout=3) as response:
                if json.load(response)["status"] != "ready":
                    raise RuntimeError("relay is not ready")
        await asyncio.to_thread(check_readiness)
        (directory / "endpoints.env").write_text(
            f"GOTSYNC_RELAY_URL=ws://127.0.0.1:{server.websocket_port}/v1\n"
            f"GOTSYNC_MAILBOX_URL=http://127.0.0.1:{server.bound_mailbox_port}/v1/mailbox\n"
        )
        stopped = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(sig, stopped.set)
        await stopped.wait()
    finally:
        await server.close()


asyncio.run(main())
