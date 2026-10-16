import base64
import concurrent.futures
import hashlib
import json

import pytest

from gotsync_server.mls import MLSStore


def blob(value):
    return base64.b64encode(value).decode()


TOKEN = blob(b'a' * 32)
TOKEN_B = blob(b'b' * 32)
ROUTE = 'g' * 32
PAIR = 'p' * 32


def request(store, op, **fields):
    return store.handle(dict(version=3, operation=op, route=ROUTE, token=TOKEN, member='a', **fields))


def event(kind='commit', epoch=0, previous=0, **extra):
    return dict(kind=kind, epoch=epoch, previous=previous, payload=blob(b'mls ciphertext')) | extra


def put(store, body, operation=None):
    identifier = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return request(store, operation or body['kind'], id=identifier, event=body)


@pytest.fixture
def store(tmp_path):
    store = MLSStore(tmp_path / 'relay')
    request(store, 'createGroup')
    return store


def test_first_commit_wins_and_exact_retry_survives_reopen(store):
    bodies = [event(payload=blob(bytes([n]))) for n in range(1, 4)]
    with concurrent.futures.ThreadPoolExecutor() as pool:
        results = list(pool.map(lambda body: put(store, body), bodies))
    assert sum(result['accepted'] for result in results) == 1
    winner = bodies[next(n for n, result in enumerate(results) if result['accepted'])]
    reopened = MLSStore(store.path[:-4])
    assert put(reopened, winner) == dict(accepted=True, cursor=1)
    assert len(request(store, 'fetch')['events']) == 1


def test_refusal_tombstone_prevents_delayed_acceptance(store):
    future = event(epoch=1, previous=1)
    assert not put(store, future)['accepted']
    assert put(store, event())['accepted']
    assert not put(store, future)['accepted']
    assert len(request(store, 'fetch')['events']) == 1


def test_atomic_welcome_and_keypackage_consumption(store):
    descriptor = dict(clientID=blob(b'b'), fingerprint='fingerprint' * 4, keyPackage=blob(b'kp'), transportHash=store.token_hash(TOKEN_B))
    store.handle(dict(version=3, operation='createPair', route=PAIR, token=TOKEN_B, descriptor=dict(descriptor, keyPackage='')))
    store.handle(dict(version=3, operation='join', route=PAIR, token=TOKEN_B, descriptor=descriptor))
    pair = dict(route=PAIR, token=TOKEN_B, keyPackage=descriptor['keyPackage'], member=descriptor['clientID'], transportHash=store.token_hash(TOKEN_B), welcome=blob(b'welcome'))
    body = event(pair=pair)
    assert put(store, body)['accepted']
    welcome = store.handle(dict(version=3, operation='welcome', route=PAIR, token=TOKEN_B))['welcome']
    assert welcome['cursor'] == 1
    assert 'token' not in welcome
    assert not put(store, event(epoch=1, previous=1, pair=pair))['accepted']
    stored = request(store, 'fetch')['events'][0]
    assert 'pair' not in stored
    assert TOKEN_B not in json.dumps(stored)


def test_expired_keypackage_refusal_has_no_partial_effect(store):
    descriptor = dict(clientID=blob(b'b'), fingerprint='fingerprint' * 4, keyPackage=blob(b'kp'), transportHash=store.token_hash(TOKEN_B))
    store.handle(dict(version=3, operation='createPair', route=PAIR, token=TOKEN_B, descriptor=descriptor))
    store.handle(dict(version=3, operation='join', route=PAIR, token=TOKEN_B, descriptor=descriptor))
    with store.connect() as db:
        db.execute('UPDATE pairs SET expires=0 WHERE route=?', (PAIR,))
    body = event(pair=dict(route=PAIR, token=TOKEN_B, keyPackage=descriptor['keyPackage'], member=descriptor['clientID'], transportHash=store.token_hash(TOKEN_B), welcome=blob(b'w')))
    assert not put(store, body)['accepted']
    assert request(store, 'fetch')['events'] == []
    with store.connect() as db:
        assert db.execute('SELECT epoch FROM groups').fetchone()[0] == 0
        assert db.execute('SELECT consumed FROM pairs').fetchone()[0] == 0


def test_outsider_and_removed_member_cannot_poison_log(store):
    with pytest.raises(ValueError):
        store.handle(dict(version=3, operation='commit', route=ROUTE, token=TOKEN_B, member='stranger', id='x' * 64, event=event()))
    with store.connect() as db:
        db.execute('INSERT INTO members(route,identity,token) VALUES(?,?,?)', (ROUTE, 'b', store.token_hash(TOKEN_B)))
    assert put(store, event(remove=['b']))['accepted']
    assert not store.handle(dict(version=3, operation='commit', route=ROUTE, token=TOKEN_B, member='b', id='z' * 64, event=event(epoch=1, previous=1)))['accepted']
    assert len(request(store, 'fetch')['events']) == 1


def test_ack_prunes_only_below_offline_member_cursor(store):
    with store.connect() as db:
        db.execute('INSERT INTO members(route,identity,token) VALUES(?,?,?)', (ROUTE, 'b', store.token_hash(TOKEN_B)))
    assert put(store, event(kind='application'))['accepted']
    request(store, 'fetch', cursor=1)
    assert len(request(store, 'fetch', cursor=0)['events']) == 1
    store.handle(dict(version=3, operation='fetch', route=ROUTE, token=TOKEN_B, member='b', cursor=1))
    with store.connect() as db:
        assert db.execute('SELECT count(*) FROM events').fetchone()[0] == 0
        assert db.execute('SELECT floor,head FROM groups').fetchone() == (1, 1)
    assert put(store, event(kind='application', previous=1))['accepted']


def test_qr_directory_does_not_expose_member_capability(store):
    descriptor = dict(clientID=blob(b'b'), fingerprint='fingerprint' * 4, keyPackage=blob(b'kp'), transportHash=store.token_hash(TOKEN_B))
    store.handle(dict(version=3, operation='createPair', route=PAIR, token=TOKEN, descriptor=dict(descriptor, keyPackage='')))
    store.handle(dict(version=3, operation='join', route=PAIR, token=TOKEN, descriptor=descriptor))
    outsider = dict(descriptor, keyPackage=blob(b'outsider'))
    store.handle(dict(version=3, operation='join', route=PAIR, token=TOKEN, descriptor=outsider))
    body = event(pair=dict(route=PAIR, token=TOKEN, keyPackage=descriptor['keyPackage'], member=descriptor['clientID'], transportHash=descriptor['transportHash'], welcome=blob(b'w')))
    assert put(store, body)['accepted']
    welcome = store.handle(dict(version=3, operation='welcome', route=PAIR, token=TOKEN))
    assert TOKEN_B not in json.dumps(welcome)
    with pytest.raises(ValueError):
        store.handle(dict(version=3, operation='application', route=ROUTE, token=TOKEN, member=descriptor['clientID'], id='z' * 64, event=event(kind='application', epoch=1, previous=1)))


def test_removed_member_final_ack_prunes_and_retry_keeps_receipt(store):
    with store.connect() as db:
        db.execute('INSERT INTO members(route,identity,token) VALUES(?,?,?)', (ROUTE, 'b', store.token_hash(TOKEN_B)))
    first = event(kind='application')
    identifier = hashlib.sha256(json.dumps(first, sort_keys=True).encode()).hexdigest()
    accepted_request = dict(version=3, operation='application', route=ROUTE, token=TOKEN_B, member='b', id=identifier, event=first)
    assert store.handle(accepted_request)['accepted']
    removal = event(epoch=0, previous=1, remove=['b'])
    assert put(store, removal)['accepted']
    assert store.handle(accepted_request) == dict(accepted=True, cursor=1)
    for n in range(50):
        reply = store.handle(dict(version=3, operation='application', route=ROUTE, token=TOKEN_B, member='b', id=hashlib.sha256(str(n).encode()).hexdigest(), event=event(kind='application', epoch=1, previous=2)))
        assert not reply['accepted']
    request(store, 'fetch', cursor=2)
    store.handle(dict(version=3, operation='fetch', route=ROUTE, token=TOKEN_B, member='b', cursor=2))
    with store.connect() as db:
        assert db.execute('SELECT count(*) FROM events').fetchone()[0] == 0
        assert db.execute('SELECT count(*) FROM decisions').fetchone()[0] == 0


def test_lost_removed_device_stops_holding_floor_after_one_day(store):
    with store.connect() as db:
        db.execute('INSERT INTO members(route,identity,token) VALUES(?,?,?)', (ROUTE, 'b', store.token_hash(TOKEN_B)))
    assert put(store, event(remove=['b']))['accepted']
    with store.connect() as db:
        db.execute('UPDATE members SET removed_time=0 WHERE identity=?', ('b',))
    request(store, 'fetch', cursor=1)
    with store.connect() as db:
        assert db.execute('SELECT count(*) FROM events').fetchone()[0] == 0


def test_forget_retires_group_and_releases_creation_slot(store):
    request(store, 'forget')
    with store.connect() as db:
        assert db.execute('SELECT retired FROM groups').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM members').fetchone()[0] == 0
    with pytest.raises(ValueError):
        request(store, 'createGroup')
    assert store.handle(dict(version=3, operation='createGroup', route='h' * 32, token=TOKEN, member='a')) == {}
