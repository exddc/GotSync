import json
from pathlib import Path

from gotsync_server.mailbox import authorize_mailbox, mailbox_route_for_auth, pairing_control_route_for_auth
from gotsync_server.protocol import MAILBOX_ROUTE_CONTEXT, PAIRING_CONTROL_ROUTE_CONTEXT


def test_version_one_route_domains_match_swift_baseline() -> None:
    path = Path(__file__).resolve().parents[2] / "Tests/GotSyncTests/Fixtures/protocol-v1.json"
    vectors = json.loads(path.read_text())
    assert MAILBOX_ROUTE_CONTEXT == b"com.gotdone.sync/mailbox-route/v1"
    assert PAIRING_CONTROL_ROUTE_CONTEXT == b"com.gotdone.sync/pairing-control-route/v2"
    for prefix in ("mailbox", "groupMailbox"):
        auth = bytes.fromhex(vectors[prefix + "Auth"])
        route = bytes.fromhex(vectors[prefix + "Route"])
        assert mailbox_route_for_auth(auth) == route
        authorize_mailbox(route, auth)
    auth = bytes(range(32))
    authorize_mailbox(pairing_control_route_for_auth(auth), auth)
