from gotsync_server.mailbox import authorize_mailbox, mailbox_route_for_auth, pairing_control_route_for_auth
from gotsync_server.protocol import MAILBOX_ROUTE_CONTEXT, PAIRING_CONTROL_ROUTE_CONTEXT

VERSION_ONE_ROUTES = [
    (
        "21e85fcaeca38092458ff8213187ec2ecd9916b2cd52bf521d9e3a64aa6de69f",
        "094c4fdd7654e4e688b4176223ec7a7edabc8b92167f78268d77b57eb4e1559e",
    ),
    (
        "5683bca32ebcf72eaa1afab1477ec655684ce7697115f472b3e9d1d138ae39dc",
        "153aec68857cfe8c8c08226992b44f10abe8a6bb3710e6e832738d6d29abdace",
    ),
]


def test_version_one_route_domains_match_released_clients() -> None:
    assert MAILBOX_ROUTE_CONTEXT == b"com.gotdone.sync/mailbox-route/v1"
    assert PAIRING_CONTROL_ROUTE_CONTEXT == b"com.gotdone.sync/pairing-control-route/v2"
    for auth_hex, route_hex in VERSION_ONE_ROUTES:
        auth = bytes.fromhex(auth_hex)
        route = bytes.fromhex(route_hex)
        assert mailbox_route_for_auth(auth) == route
        authorize_mailbox(route, auth)
    auth = bytes(range(32))
    authorize_mailbox(pairing_control_route_for_auth(auth), auth)
