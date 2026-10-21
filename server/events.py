"""Ordered, persisted event frames and replay queries from the original transport."""
import json
import time
FRAME_RETENTION = 5000

def _db_ensure_session_sync(conn, sid, ts, peer=None):
    conn.execute('INSERT OR IGNORE INTO sessions(sid,created,last_active,title,peer,next_seq) VALUES (?,?,?,?,?,1)', (sid, ts, ts, None, peer))
    conn.commit()

def _db_get_session_row_sync(conn, sid):
    cur = conn.execute('SELECT sid,created,last_active,title,peer,next_seq FROM sessions WHERE sid=?', (sid,))
    return cur.fetchone()

def _db_emit_sync(conn, sid, typ, kw):
    cur = conn.execute('SELECT next_seq FROM sessions WHERE sid=?', (sid,))
    row = cur.fetchone()
    seq = row[0] if row else 1
    now = time.time()
    payload = {'type': typ, 'seq': seq, 'ts': time.strftime('%H:%M:%S'), **kw}
    payload_json = json.dumps(payload, ensure_ascii=False)
    conn.execute('UPDATE sessions SET next_seq=?, last_active=? WHERE sid=?', (seq + 1, now, sid))
    conn.execute('INSERT INTO frames(sid,seq,ts,typ,payload) VALUES (?,?,?,?,?)', (sid, seq, now, typ, payload_json))
    if seq % 50 == 0:
        conn.execute('DELETE FROM frames WHERE sid=? AND seq<=?', (sid, seq - FRAME_RETENTION))
    conn.commit()
    return (seq, payload_json)

def _db_frames_since_sync(conn, sid, since, limit=None):
    if limit:
        cur = conn.execute('SELECT payload FROM frames WHERE sid=? AND seq>? ORDER BY seq LIMIT ?', (sid, since, limit))
    else:
        cur = conn.execute('SELECT payload FROM frames WHERE sid=? AND seq>? ORDER BY seq', (sid, since))
    return [r[0] for r in cur.fetchall()]

def _db_sessions_list_sync(conn, limit):
    cur = conn.execute('SELECT s.sid, s.created, s.last_active, s.title, s.peer,\n                  (SELECT COUNT(*) FROM frames f WHERE f.sid=s.sid) AS fc\n           FROM sessions s ORDER BY s.last_active DESC LIMIT ?', (limit,))
    return cur.fetchall()
