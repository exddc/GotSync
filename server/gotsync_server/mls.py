from __future__ import annotations

import base64
import hashlib
import json
import secrets
import sqlite3
import time
from pathlib import Path


class MLSStore:
    MAX_EVENTS = 10000
    MAX_BYTES = 16 * 1024 * 1024

    def __init__(self, path: str | Path):
        self.path = str(path) + '.mls'
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS groups(route TEXT PRIMARY KEY, token TEXT, epoch INTEGER,
                    head INTEGER DEFAULT 0, floor INTEGER DEFAULT 0, retired INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS members(route TEXT, identity TEXT, token TEXT, active INTEGER DEFAULT 1,
                    ack INTEGER DEFAULT 0, removed_at INTEGER, removed_time REAL, PRIMARY KEY(route,identity));
                CREATE TABLE IF NOT EXISTS events(route TEXT, seq INTEGER, body TEXT, PRIMARY KEY(route,seq));
                CREATE TABLE IF NOT EXISTS decisions(route TEXT, id TEXT, digest TEXT, accepted INTEGER, seq INTEGER,
                    previous INTEGER, PRIMARY KEY(route,id));
                CREATE TABLE IF NOT EXISTS pairs(route TEXT PRIMARY KEY, token TEXT, expires REAL, host TEXT,
                    welcome TEXT, consumed INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS packages(route TEXT, ref TEXT, descriptor TEXT, PRIMARY KEY(route,ref));
            ''')

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.execute('PRAGMA synchronous=FULL')
        return db

    @staticmethod
    def blob(value, maximum=384 * 1024):
        if not isinstance(value, str):
            raise ValueError('invalid bytes')
        raw = base64.b64decode(value, validate=True)
        if not raw or len(raw) > maximum or base64.b64encode(raw).decode() != value:
            raise ValueError('invalid bytes')
        return raw

    def token_hash(self, token):
        raw = self.blob(token, 32)
        if len(raw) != 32:
            raise ValueError('invalid capability')
        return base64.b64encode(hashlib.sha256(raw).digest()).decode()

    def space(self, db, route):
        count, size = db.execute('SELECT count(*),coalesce(sum(length(body)),0) FROM events WHERE route=?', (route,)).fetchone()
        decisions = db.execute('SELECT count(*) FROM decisions WHERE route=?', (route,)).fetchone()[0]
        return count < self.MAX_EVENTS and size < self.MAX_BYTES - 512 * 1024 and decisions < 20000

    def handle(self, request):
        if request.get('version') != 3:
            raise ValueError('unsupported version')
        op, route, token = request['operation'], request['route'], request['token']
        if not isinstance(route, str) or not 16 <= len(route) <= 128:
            raise ValueError('invalid route')
        token_hash = self.token_hash(token)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            if op == 'createGroup':
                row = db.execute('SELECT token,retired FROM groups WHERE route=?', (route,)).fetchone()
                if row is None:
                    if db.execute('SELECT count(*) FROM groups WHERE retired=0').fetchone()[0] >= 128:
                        raise ValueError('capacity')
                    db.execute('INSERT INTO groups(route,token,epoch) VALUES(?,?,0)', (route, token_hash))
                    db.execute('INSERT INTO members(route,identity,token) VALUES(?,?,?)', (route, request['member'], token_hash))
                elif row[1] or not secrets.compare_digest(row[0], token_hash):
                    raise ValueError('unauthorized')
                return {}
            if op == 'createPair':
                descriptor = request['descriptor']
                self.descriptor(descriptor, require_package=False)
                encoded = json.dumps(descriptor, sort_keys=True)
                db.execute('DELETE FROM packages WHERE route IN (SELECT route FROM pairs WHERE expires<?)', (time.time(),))
                db.execute('DELETE FROM pairs WHERE expires<? AND (welcome IS NULL OR expires<?)', (time.time(), time.time() - 30 * 86400))
                row = db.execute('SELECT token,host FROM pairs WHERE route=?', (route,)).fetchone()
                if row:
                    if not secrets.compare_digest(row[0], token_hash) or row[1] != encoded:
                        raise ValueError('conflict')
                else:
                    if db.execute('SELECT count(*) FROM pairs').fetchone()[0] >= 1024:
                        raise ValueError('capacity')
                    db.execute('INSERT INTO pairs(route,token,expires,host) VALUES(?,?,?,?)', (route, token_hash, time.time() + 900, encoded))
                return {}
            if op in ('pair', 'join', 'welcome'):
                row = db.execute('SELECT token,expires,host,welcome,consumed FROM pairs WHERE route=?', (route,)).fetchone()
                if not row or not secrets.compare_digest(row[0], token_hash):
                    raise ValueError('unauthorized')
                if op == 'join':
                    if row[1] < time.time() or row[4]:
                        raise ValueError('expired')
                    descriptor = request['descriptor']
                    self.descriptor(descriptor)
                    ref = hashlib.sha256(self.blob(descriptor['keyPackage'])).hexdigest()
                    if db.execute('SELECT count(*) FROM packages WHERE route=?', (route,)).fetchone()[0] >= 8:
                        existing = db.execute('SELECT 1 FROM packages WHERE route=? AND ref=?', (route, ref)).fetchone()
                        if not existing:
                            raise ValueError('capacity')
                    db.execute('INSERT INTO packages VALUES(?,?,?) ON CONFLICT DO NOTHING', (route, ref, json.dumps(descriptor, sort_keys=True)))
                    return {}
                ready = False
                if request.get('descriptor'):
                    ref = hashlib.sha256(self.blob(request['descriptor']['keyPackage'])).hexdigest()
                    ready = db.execute('SELECT 1 FROM packages WHERE route=? AND ref=?', (route, ref)).fetchone() is not None
                return {'host': json.loads(row[2]), 'welcome': json.loads(row[3]) if row[3] else None, 'expired': row[1] < time.time(), 'ready': ready}
            group = db.execute('SELECT epoch,head,floor,retired FROM groups WHERE route=?', (route,)).fetchone()
            member = db.execute('SELECT token,active,ack,removed_at FROM members WHERE route=? AND identity=?', (route, request['member'])).fetchone()
            if not group or group[3] or not member or not secrets.compare_digest(member[0], token_hash):
                raise ValueError('unauthorized')
            if op == 'forget':
                db.execute('UPDATE members SET active=0,ack=?,removed_at=?,removed_time=? WHERE route=? AND identity=?', (group[1], group[1], time.time(), route, request['member']))
                if db.execute('SELECT count(*) FROM members WHERE route=? AND active=1', (route,)).fetchone()[0] == 0:
                    db.execute('UPDATE groups SET retired=1 WHERE route=?', (route,))
                    for table in ('events', 'decisions', 'members'):
                        db.execute(f'DELETE FROM {table} WHERE route=?', (route,))
                return {}
            if op == 'fetch':
                cursor = request.get('cursor', 0)
                if type(cursor) is not int or cursor < group[2] or cursor > group[1]:
                    raise ValueError('historyUnavailable')
                db.execute('UPDATE members SET ack=max(ack,?) WHERE route=? AND identity=?', (cursor, route, request['member']))
                floor = db.execute('SELECT min(ack) FROM members WHERE route=? AND (active=1 OR (ack<removed_at AND removed_time>?))', (route, time.time() - 86400)).fetchone()[0]
                if floor is not None:
                    db.execute('DELETE FROM events WHERE route=? AND seq<=?', (route, floor))
                    db.execute('DELETE FROM decisions WHERE route=? AND ((accepted=1 AND seq<=?) OR (accepted=0 AND previous<?))', (route, floor, floor))
                    db.execute('UPDATE groups SET floor=max(floor,?) WHERE route=?', (floor, route))
                ceiling = group[1] if member[1] else member[3]
                rows = db.execute('SELECT seq,body FROM events WHERE route=? AND seq>? AND seq<=? ORDER BY seq LIMIT 16', (route, cursor, ceiling)).fetchall()
                return {'events': [dict(json.loads(body), cursor=seq) for seq, body in rows], 'canAppend': self.space(db, route)}
            if op not in ('commit', 'application', 'refuse'):
                raise ValueError('operation')
            identifier, body = request['id'], request['event']
            if not isinstance(identifier, str) or len(identifier) != 64:
                raise ValueError('id')
            digest = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            decision = db.execute('SELECT digest,accepted,seq FROM decisions WHERE route=? AND id=?', (route, identifier)).fetchone()
            if decision:
                if decision[0] != digest:
                    raise ValueError('id conflict')
                return {'accepted': bool(decision[1]), 'cursor': decision[2]}
            if not member[1]:
                return {'accepted': False, 'cursor': 0}
            epoch, previous = body['epoch'], body['previous']
            if type(epoch) is not int or not 0 <= epoch < 2**53 or type(previous) is not int or not 0 <= previous < 2**53:
                raise ValueError('epoch')
            self.blob(body['payload'])
            if body['kind'] != op and op != 'refuse':
                raise ValueError('kind')
            if previous < group[2]:
                return {'accepted': False, 'cursor': 0}
            available = self.space(db, route)
            if not available:
                return {'capacity': True}
            accepted = op != 'refuse' and bool(member[1]) and epoch == group[0] and previous == group[1]
            package = None
            if op == 'commit' and body.get('pair'):
                p = body['pair']
                ref = hashlib.sha256(self.blob(p['keyPackage'])).hexdigest()
                package = db.execute('SELECT p.token,p.expires,p.consumed,k.descriptor FROM pairs p JOIN packages k ON p.route=k.route WHERE p.route=? AND k.ref=?', (p['route'], ref)).fetchone()
                descriptor = json.loads(package[3]) if package else None
                accepted = accepted and bool(package and secrets.compare_digest(package[0], self.token_hash(p['token']))
                    and package[1] >= time.time() and not package[2]
                    and descriptor['keyPackage'] == p['keyPackage'] and descriptor['clientID'] == p['member']
                    and descriptor['transportHash'] == p['transportHash'])
                self.blob(p['welcome'])
            seq = group[1] + 1 if accepted else 0
            db.execute('INSERT INTO decisions VALUES(?,?,?,?,?,?)', (route, identifier, digest, int(accepted), seq, previous))
            if not accepted:
                return {'accepted': False, 'cursor': 0}
            stored = {key: value for key, value in body.items() if key != 'pair'}
            db.execute('INSERT INTO events VALUES(?,?,?)', (route, seq, json.dumps(stored, sort_keys=True)))
            db.execute('UPDATE groups SET head=? WHERE route=?', (seq, route))
            if op == 'commit':
                for identity in body.get('remove', []):
                    db.execute('UPDATE members SET active=0,removed_at=?,removed_time=? WHERE route=? AND identity=?', (seq, time.time(), route, identity))
                db.execute('UPDATE groups SET epoch=epoch+1 WHERE route=?', (route,))
                if package:
                    p = body['pair']
                    db.execute('INSERT INTO members(route,identity,token,ack) VALUES(?,?,?,?) ON CONFLICT(route,identity) DO UPDATE SET token=excluded.token,active=1,ack=excluded.ack,removed_at=NULL,removed_time=NULL', (route, p['member'], p['transportHash'], seq))
                    welcome = dict(payload=p['welcome'], group=route, cursor=seq, epoch=epoch + 1)
                    db.execute('UPDATE pairs SET consumed=1,welcome=? WHERE route=?', (json.dumps(welcome), p['route']))
            return {'accepted': True, 'cursor': seq}

    def descriptor(self, value, require_package=True):
        if require_package:
            self.blob(value['keyPackage'], 16384)
            if len(self.blob(value['transportHash'], 32)) != 32:
                raise ValueError('transport hash')
        self.blob(value['clientID'], 256)
        if not isinstance(value['fingerprint'], str) or not 20 <= len(value['fingerprint']) <= 128:
            raise ValueError('fingerprint')
