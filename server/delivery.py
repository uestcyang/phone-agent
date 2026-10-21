"""Persistent message receipt and restart recovery, extracted from the original transport."""
import json
import re
import time
PROTOCOL = "message-ack-v1"
_ID = re.compile(r"[A-Za-z0-9_-]{16,96}\Z")

def validate_id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError('invalid client message id')
    return value

def initialize(conn):
    conn.execute('CREATE TABLE IF NOT EXISTS message_inbox(\n        sid TEXT NOT NULL, mid TEXT NOT NULL, qid INTEGER NOT NULL,\n        payload TEXT NOT NULL, status TEXT NOT NULL,\n        created REAL NOT NULL, updated REAL NOT NULL,\n        PRIMARY KEY(sid,mid))')
    conn.execute('CREATE TABLE IF NOT EXISTS message_owner(\n        sid TEXT NOT NULL, mid TEXT NOT NULL,\n        job_id TEXT NOT NULL, run_id TEXT NOT NULL,\n        role TEXT NOT NULL, nonce TEXT NOT NULL,\n        next_decision_json TEXT,\n        stop_evidence_json TEXT,\n        bound_at REAL NOT NULL,\n        bound_source TEXT,\n        PRIMARY KEY(sid,mid))')

def content(payload):
    """"""
    return json.dumps({k: payload.get(k) for k in ('text', 'attachments', 'type')}, ensure_ascii=False, sort_keys=True, separators=(',', ':'))

def accept(conn, sid, mid, qid, payload):
    validate_id(mid)
    encoded = content(payload)
    row = conn.execute('SELECT qid,payload,status FROM message_inbox WHERE sid=? AND mid=?', (sid, mid)).fetchone()
    if row:
        if row[1] != encoded:
            raise ValueError('message id content conflict')
        return dict(inserted=False, qid=row[0], status=row[2])
    now = time.time()
    conn.execute('INSERT INTO message_inbox VALUES (?,?,?,?,?,?,?)', (sid, mid, qid, encoded, 'queued', now, now))
    conn.commit()
    return dict(inserted=True, qid=qid, status='queued')

def start(conn, sid, mid):
    changed = conn.execute("UPDATE message_inbox SET status='started',updated=? WHERE sid=? AND mid=? AND status='queued'", (time.time(), sid, mid)).rowcount
    conn.commit()
    return changed == 1

def finish(conn, sid, mid, status='finished'):
    conn.execute("UPDATE message_inbox SET status=?,updated=? WHERE sid=? AND mid=? AND status='started'", (status, time.time(), sid, mid))
    conn.commit()

def cancel(conn, sid, qid=None):
    query = "UPDATE message_inbox SET status='cancelled',updated=? WHERE sid=? AND status='queued'"
    args = [time.time(), sid]
    if qid is not None:
        query += ' AND qid=?'
        args.append(qid)
    conn.execute(query, args)
    conn.commit()

def recover(conn, sid):
    """"""
    rows = conn.execute('SELECT mid,qid,payload,status FROM message_inbox WHERE sid=? ORDER BY created,qid', (sid,)).fetchall()
    queued, interrupted = ([], [])
    owner_rows = conn.execute('SELECT mid, job_id, run_id, role, nonce, next_decision_json, stop_evidence_json FROM message_owner WHERE sid=?', (sid,)).fetchall()
    owner_by_mid = {r[0]: dict(job_id=r[1], run_id=r[2], role=r[3], nonce=r[4], next_decision=json.loads(r[5]) if r[5] else None, stop_evidence=json.loads(r[6]) if r[6] else None) for r in owner_rows}
    for mid, qid, payload, status in rows:
        if status == 'queued':
            item = dict(json.loads(payload), qid=qid, client_message_id=mid)
            owner = owner_by_mid.get(mid)
            item['_owner'] = owner
            queued.append(item)
        elif status == 'started':
            interrupted.append(mid)
    conn.execute("UPDATE message_inbox SET status='interrupted',updated=? WHERE sid=? AND status='started'", (time.time(), sid))
    conn.commit()
    return (queued, interrupted, max((r[1] for r in rows), default=0))
