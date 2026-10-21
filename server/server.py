"""Standalone transport for the Android client and a configured native executor.

No model loop, account discovery, automatic device access, or deployment probing
is implemented here. The operator supplies one trusted executable adapter.
"""
from __future__ import annotations
import asyncio
import contextlib
import fcntl
import hashlib
import hmac
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import stat
import sys
import time
import uuid
from aiohttp import web, WSMsgType
import delivery
import events

ID = re.compile(r"[A-Za-z0-9_-]{1,96}\Z")
MAX_FILE = 16 * 1024 * 1024
MAX_TEXT = 128 * 1024


def private_dir(path: Path) -> Path:
    path = path.absolute()
    if any(p.is_symlink() for p in [path, *path.parents]):
        raise ValueError("Storage cannot traverse symlinks")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def read_regular(path: Path, root: Path, maximum: int = MAX_FILE) -> bytes:
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Symlink artifact rejected")
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > maximum:
            raise ValueError("Invalid artifact")
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Artifact exceeds limit")
        return data
    finally:
        os.close(fd)


class Service:
    def __init__(self, root: Path, admin_token: str, command: list[str], timeout: float = 300):
        if len(admin_token) < 24:
            raise ValueError("PA_ADMIN_TOKEN must be explicitly configured with at least 24 characters")
        if not command or not all(isinstance(x, str) and x for x in command):
            raise ValueError("PA_RUNNER_COMMAND must be a nonempty JSON argv array")
        self.root = private_dir(root)
        self.admin_token = admin_token
        self.command = command
        self.timeout = timeout
        lock_fd = os.open(self.root / '.instance.lock', os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        self.lock = os.fdopen(lock_fd, 'a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            self.lock.close()
            raise
        db_path = self.root / 'state.sqlite3'
        if db_path.is_symlink():
            raise ValueError("Database cannot be a symlink")
        self.db = sqlite3.connect(db_path)
        db_path.chmod(0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS sessions(sid TEXT PRIMARY KEY,created REAL,last_active REAL,title TEXT,peer TEXT,next_seq INTEGER DEFAULT 1);
          CREATE TABLE IF NOT EXISTS frames(sid TEXT,seq INTEGER,ts REAL,typ TEXT,payload TEXT,PRIMARY KEY(sid,seq));
          CREATE TABLE IF NOT EXISTS devices(digest TEXT PRIMARY KEY,principal TEXT UNIQUE,revoked INTEGER DEFAULT 0);
          CREATE TABLE IF NOT EXISTS files(rel TEXT PRIMARY KEY,principal TEXT,path TEXT,name TEXT,mime TEXT,size INTEGER,digest TEXT);
          CREATE TABLE IF NOT EXISTS network_events(principal TEXT,id TEXT,payload TEXT,PRIMARY KEY(principal,id));
        ''')
        delivery.initialize(self.db)
        self.db.commit()
        self.pairings: dict[str, dict] = {}
        self.peers: dict[str, set] = {}
        self.tasks: dict[str, asyncio.Task] = {}
        self.processes: dict[str, asyncio.subprocess.Process] = {}
        self.recovered: set[str] = set()
        self.pair_rate: dict[str, list[float]] = {}
        self.app = web.Application(client_max_size=MAX_FILE)
        self.app.add_routes([
            web.get('/pair/request', self.pair_request),
            web.get('/pair/poll', self.pair_poll),
            web.post('/pair/approve', self.pair_approve),
            web.post('/pair/revoke', self.pair_revoke),
            web.get('/healthz', self.health), web.get('/roles', self.roles),
            web.get('/sessions', self.sessions), web.get('/ws', self.websocket),
            web.get('/tasks', self.task_list), web.get('/widget_summary', self.task_list),
            web.post('/upload', self.upload), web.get('/upload/{day}/{name}', self.download),
        ])
        self.app.on_cleanup.append(self.cleanup)

    def identity(self, request: web.Request, *, admin=False, media=False) -> str:
        header = request.headers.get('Authorization', '')
        token = header[7:] if header.startswith('Bearer ') else ''
        if not token and media:
            token = request.query.get('token', '')
        if token and hmac.compare_digest(token, self.admin_token):
            return 'administrator'
        if not admin and token:
            row = self.db.execute('SELECT principal FROM devices WHERE digest=? AND revoked=0', (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
            if row:
                return row[0]
        raise web.HTTPUnauthorized(text='Authentication required')

    def authorize_session(self, principal: str, sid: str):
        row = events._db_get_session_row_sync(self.db, sid)
        if not row or row[4] != principal:
            raise ValueError('Unknown session or incorrect device')
        return row

    def gc_pairings(self):
        now = time.time()
        self.pairings = {k: v for k, v in self.pairings.items() if v['expires'] > now}
        if len(self.pairings) >= 100:
            raise web.HTTPTooManyRequests()

    async def pair_request(self, request):
        self.gc_pairings()
        key = request.remote or 'unknown'
        now = time.time()
        timestamps = [x for x in self.pair_rate.get(key, []) if x > now - 60]
        if len(timestamps) >= 10:
            raise web.HTTPTooManyRequests()
        self.pair_rate[key] = timestamps + [now]
        pid = secrets.token_urlsafe(32)
        code = f'{secrets.randbelow(1000000):06d}'
        self.pairings[pid] = {'code': code, 'expires': now + 300, 'status': 'pending'}
        return web.json_response({'ok': True, 'pairing_id': pid, 'code': code, 'expires_in': 300})

    async def pair_poll(self, request):
        self.gc_pairings()
        rec = self.pairings.get(request.query.get('pairing_id', ''))
        if not rec:
            raise web.HTTPNotFound()
        result = {'ok': True, 'status': rec['status']}
        if rec['status'] == 'approved':
            result.update(token=rec['token'], device_id=rec['principal'])
        return web.json_response(result, headers={'Cache-Control': 'no-store'})

    async def pair_approve(self, request):
        self.identity(request, admin=True)
        self.gc_pairings()
        data = await request.json()
        matches = [(k,v) for k,v in self.pairings.items() if hmac.compare_digest(v['code'], str(data.get('code', ''))) and (not data.get('pairing_id') or k == data['pairing_id'])]
        if len(matches) != 1:
            raise web.HTTPBadRequest(text='Pairing code missing, expired, or ambiguous')
        _, rec = matches[0]
        if rec['status'] == 'pending':
            token = secrets.token_urlsafe(32)
            principal = uuid.uuid4().hex
            self.db.execute('INSERT INTO devices VALUES (?,?,0)', (hashlib.sha256(token.encode()).hexdigest(), principal))
            self.db.commit()
            rec.update(status='approved', token=token, principal=principal)
        return web.json_response({'ok': True, 'device_id': rec['principal']})

    async def pair_revoke(self, request):
        self.identity(request, admin=True)
        data = await request.json()
        principal = data.get('device_id', '')
        self.db.execute('UPDATE devices SET revoked=1 WHERE principal=?', (principal,))
        self.db.commit()
        for sid, peers in list(self.peers.items()):
            row = events._db_get_session_row_sync(self.db, sid)
            if row and row[4] == principal:
                self.db.execute("UPDATE message_inbox SET status='cancelled' WHERE sid=? AND status='queued'", (sid,))
                self.db.commit()
                proc = self.processes.get(sid)
                if proc and proc.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(proc.pid, signal.SIGTERM)
                for ws in list(peers):
                    await ws.close(code=1008, message=b'Device revoked')
        return web.json_response({'ok': True})

    async def health(self, request):
        self.identity(request)
        return web.json_response({'ok': True, 'backend': 'native-command', 'model': 'configured executor', 'message_delivery': delivery.PROTOCOL, 'capabilities': {'incognito': False, 'voice': False, 'device_bridge': False, 'private_account_metrics': False}})

    async def roles(self, request):
        self.identity(request)
        return web.json_response({'roles': [{'name': 'agent_a', 'alive': True, 'model': 'configured executor'}]})

    async def sessions(self, request):
        principal = self.identity(request)
        rows = self.db.execute('SELECT sid,title,last_active FROM sessions WHERE peer=? ORDER BY last_active DESC LIMIT 100', (principal,)).fetchall()
        return web.json_response({'sessions': [dict(sid=x[0],title=x[1] or 'Session',last_active=x[2]) for x in rows]})

    async def task_list(self, request):
        principal = self.identity(request)
        rows = self.db.execute('SELECT i.sid,i.mid,i.qid,i.status FROM message_inbox i JOIN sessions s USING(sid) WHERE s.peer=? ORDER BY i.created DESC LIMIT 100', (principal,)).fetchall()
        return web.json_response({'ok': True, 'items': [dict(sid=x[0],id=x[1],qid=x[2],state=x[3]) for x in rows]})

    async def emit(self, sid: str, kind: str, **values):
        _, encoded = events._db_emit_sync(self.db, sid, kind, values)
        for ws in list(self.peers.get(sid, ())):
            try:
                await ws.send_str(encoded)
            except (ConnectionError, RuntimeError):
                self.peers[sid].discard(ws)

    def lookup_file(self, rel: str, principal: str):
        row = self.db.execute('SELECT path,name,mime,size,digest FROM files WHERE rel=? AND principal=?', (rel,principal)).fetchone()
        if not row:
            raise ValueError('Unknown file or incorrect device')
        return row

    def save_file(self, principal: str, name: str, data: bytes, mime: str):
        safe_name = re.sub(r'[^A-Za-z0-9._-]', '_', Path(name).name)[:96] or 'file.bin'
        day = time.strftime('%Y%m%d')
        filename = secrets.token_hex(16) + '_' + safe_name
        folder = private_dir(self.root / 'uploads' / day)
        path = folder / filename
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        rel = f'/upload/{day}/{filename}'
        digest = hashlib.sha256(data).hexdigest()
        mime = mime if re.fullmatch(r'[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+', mime or '') else 'application/octet-stream'
        self.db.execute('INSERT INTO files VALUES (?,?,?,?,?,?,?)', (rel,principal,str(path),safe_name,mime,len(data),digest))
        self.db.commit()
        return {'rel': rel, 'url': rel, 'name': safe_name, 'mime': mime, 'size': len(data), 'sha256': digest, 'kind': 'file'}

    async def upload(self, request):
        principal = self.identity(request)
        info = self.save_file(principal, request.headers.get('X-Filename','file.bin'), await request.read(), request.headers.get('X-Mime','application/octet-stream'))
        return web.json_response({'ok': True, **info})

    async def download(self, request):
        principal = self.identity(request, media=True)
        try:
            row = self.lookup_file(request.path, principal)
            data = read_regular(Path(row[0]), self.root / 'uploads')
        except (ValueError, OSError):
            raise web.HTTPNotFound()
        return web.Response(body=data, headers={'Content-Type': row[2], 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff'})

    async def websocket(self, request):
        principal = self.identity(request)
        ws = web.WebSocketResponse(max_msg_size=MAX_TEXT * 2, heartbeat=25)
        await ws.prepare(request)
        sid = None
        try:
            async for frame in ws:
                if frame.type != WSMsgType.TEXT:
                    continue
                try:
                    self.identity(request)
                    msg = json.loads(frame.data)
                    if not isinstance(msg, dict):
                        raise ValueError('Message must be an object')
                    typ = msg.get('type', 'user')
                    if typ == 'ping':
                        await ws.send_json({'type':'pong','seq':msg.get('seq')})
                        continue
                    if typ == 'hello':
                        if msg.get('incognito'):
                            raise ValueError('Incognito is unavailable in this release; no session was created')
                        requested = msg.get('sid')
                        if requested is not None and (not isinstance(requested,str) or not ID.fullmatch(requested)):
                            raise ValueError('Invalid session id')
                        new_sid = requested or uuid.uuid4().hex
                        previous = events._db_get_session_row_sync(self.db,new_sid)
                        if previous:
                            self.authorize_session(principal,new_sid)
                        else:
                            events._db_ensure_session_sync(self.db,new_sid,time.time(),principal)
                        if sid:
                            self.peers.get(sid,set()).discard(ws)
                        sid = new_sid
                        self.peers.setdefault(sid,set()).add(ws)
                        if sid not in self.recovered:
                            _, interrupted, _ = delivery.recover(self.db,sid)
                            self.recovered.add(sid)
                            for mid in interrupted:
                                events._db_emit_sync(self.db,sid,'error',{'client_message_id':mid,'text':'Execution was interrupted by restart. It was not automatically repeated.'})
                        row = self.authorize_session(principal,sid)
                        await ws.send_json({'type':'session','sid':sid,'server_seq':row[5]-1,'resumed':bool(previous),'busy':sid in self.tasks,'message_delivery':delivery.PROTOCOL,'network_events':'durable-network-v1'})
                        if previous:
                            since = msg.get('last_seq',0)
                            if type(since) is not int or since<0:
                                raise ValueError('Invalid replay position')
                            frames = events._db_frames_since_sync(self.db,sid,since)
                            await ws.send_json({'type':'replay_start','count':len(frames)})
                            for value in frames:
                                await ws.send_str(value)
                            await ws.send_json({'type':'replay_end'})
                        self.schedule(sid,principal)
                        continue
                    if not sid:
                        raise ValueError('Send hello before other messages')
                    self.authorize_session(principal,sid)
                    if typ == 'network_event':
                        event = msg.get('event') or {}
                        eid = event.get('event_id') or event.get('id')
                        delivery.validate_id(eid)
                        payload = json.dumps(event,sort_keys=True,separators=(',',':'))
                        old = self.db.execute('SELECT payload FROM network_events WHERE principal=? AND id=?',(principal,eid)).fetchone()
                        if old and old[0]!=payload:
                            raise ValueError('Network event id conflict')
                        self.db.execute('INSERT OR IGNORE INTO network_events VALUES (?,?,?)',(principal,eid,payload));self.db.commit()
                        await ws.send_json({'type':'network_event_ack','event_id':eid,'durable':True})
                    elif typ == 'stop':
                        proc = self.processes.get(sid)
                        if proc and proc.returncode is None:
                            os.killpg(proc.pid,signal.SIGTERM)
                    elif typ == 'unqueue':
                        qid=msg.get('qid')
                        if type(qid) is not int:
                            raise ValueError('Invalid queue id')
                        self.db.execute("UPDATE message_inbox SET status='cancelled' WHERE sid=? AND qid=? AND status='queued'",(sid,qid));self.db.commit()
                    elif typ == 'state_sync':
                        await ws.send_json({'type':'status','busy':sid in self.tasks,'text':'running' if sid in self.tasks else 'idle'})
                    elif typ in ('user','steer'):
                        if msg.get('text') in ('/reset', '/clear'):
                            self.peers.get(sid,set()).discard(ws)
                            sid=uuid.uuid4().hex
                            events._db_ensure_session_sync(self.db,sid,time.time(),principal)
                            self.peers.setdefault(sid,set()).add(ws)
                            self.recovered.add(sid)
                            await ws.send_json({'type':'session','sid':sid,'server_seq':0,'resumed':False,'busy':False,'message_delivery':delivery.PROTOCOL,'network_events':'durable-network-v1'})
                            continue
                        if msg.get('sid',sid)!=sid:
                            raise ValueError('Session mismatch')
                        text=msg.get('text','')
                        if not isinstance(text,str) or len(text)>MAX_TEXT:
                            raise ValueError('Invalid text')
                        mid=msg.get('client_message_id')
                        delivery.validate_id(mid)
                        attachments=msg.get('attachments') or []
                        if not isinstance(attachments,list) or len(attachments)>20:
                            raise ValueError('Invalid attachment list')
                        for item in attachments:
                            if not isinstance(item,dict):raise ValueError('Invalid attachment')
                            self.lookup_file(item.get('rel',''),principal)
                        pending=self.db.execute("SELECT COUNT(*) FROM message_inbox WHERE sid=? AND status='queued'",(sid,)).fetchone()[0]
                        if pending>=100 and not self.db.execute('SELECT 1 FROM message_inbox WHERE sid=? AND mid=?',(sid,mid)).fetchone():raise ValueError('Queue full')
                        qid=self.db.execute('SELECT COALESCE(MAX(qid),0)+1 FROM message_inbox WHERE sid=?',(sid,)).fetchone()[0]
                        receipt=delivery.accept(self.db,sid,mid,qid,msg)
                        await ws.send_json({'type':'message_ack','sid':sid,'client_message_id':mid,'qid':receipt['qid'],'status':receipt['status'],'durable':True})
                        self.schedule(sid,principal)
                    else:
                        raise ValueError('Unsupported operation')
                except web.HTTPUnauthorized:
                    await ws.close(code=1008,message=b'Device revoked')
                    break
                except (ValueError,TypeError,KeyError) as exc:
                    parsed = locals().get('msg',{})
                    await ws.send_json({'type':'message_rejected' if isinstance(parsed,dict) and parsed.get('client_message_id') else 'error','client_message_id':parsed.get('client_message_id') if isinstance(parsed,dict) else None,'text':str(exc)[:200]})
        finally:
            if sid:self.peers.get(sid,set()).discard(ws)
        return ws

    def schedule(self,sid,principal):
        if sid not in self.tasks or self.tasks[sid].done():
            task=asyncio.create_task(self.drain(sid,principal));self.tasks[sid]=task

    async def bounded_read(self,reader,limit):
        chunks=[];size=0
        while True:
            chunk=await reader.read(65536)
            if not chunk:return b''.join(chunks)
            size+=len(chunk)
            if size>limit:raise ValueError('Executor output exceeded limit')
            chunks.append(chunk)

    async def execute(self,sid,principal,item,mid):
        work=private_dir(self.root/'jobs'/sid/mid)
        home=private_dir(work/'.home')
        attach=[]
        for a in item.get('attachments') or []:
            row=self.lookup_file(a['rel'],principal)
            attach.append({'name':row[1],'path':row[0],'mime':row[2]})
        env={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'HOME':str(home),'LANG':'C.UTF-8','PYTHONIOENCODING':'utf-8'}
        explicit=json.loads(os.environ.get('PA_RUNNER_ENV_JSON','{}'))
        if not isinstance(explicit,dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in explicit.items()):
            raise ValueError('Invalid executor environment configuration')
        env.update(explicit)
        history=[json.loads(x) for x in events._db_frames_since_sync(self.db,sid,max(0,self.authorize_session(principal,sid)[5]-100)) if json.loads(x).get('type') in ('user','assistant')]
        request={'session_id':sid,'message_id':mid,'text':item.get('text',''),'attachments':attach,'history':history}
        proc=await asyncio.create_subprocess_exec(*self.command,cwd=work,env=env,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,start_new_session=True)
        self.processes[sid]=proc
        try:
            proc.stdin.write(json.dumps(request,ensure_ascii=False).encode());await proc.stdin.drain();proc.stdin.close()
            async def collect():
                output,errors=await asyncio.gather(self.bounded_read(proc.stdout,1024*1024),self.bounded_read(proc.stderr,65536))
                await proc.wait();return output,errors
            output,_=await asyncio.wait_for(collect(),timeout=self.timeout)
            if proc.returncode!=0:raise ValueError('Configured executor failed or was stopped')
            result=json.loads(output)
            if not isinstance(result,dict) or not isinstance(result.get('text'),str):
                raise ValueError('Executor must return a JSON object with a text string')
            files=result.get('files',[])
            if not isinstance(files,list) or len(files)>20:raise ValueError('Invalid executor artifact list')
            published=[]
            for name in files:
                if not isinstance(name,str):raise ValueError('Invalid artifact name')
                rel=Path(name)
                if rel.is_absolute() or '..' in rel.parts or not rel.parts:raise ValueError('Artifact path traversal rejected')
                data=read_regular(work/rel,work)
                published.append(self.save_file(principal,rel.name,data,mimetypes.guess_type(rel.name)[0] or 'application/octet-stream'))
            return result['text'],published
        finally:
            if proc.returncode is None:
                with contextlib.suppress(ProcessLookupError):os.killpg(proc.pid,signal.SIGKILL)
                await proc.wait()
            self.processes.pop(sid,None)

    async def drain(self,sid,principal):
        try:
            while True:
                row=self.db.execute("SELECT mid,qid,payload FROM message_inbox WHERE sid=? AND status='queued' ORDER BY qid LIMIT 1",(sid,)).fetchone()
                if not row:return
                mid,qid,payload=row
                if not delivery.start(self.db,sid,mid):continue
                item=json.loads(payload)
                await self.emit(sid,'status',text='running',qid=qid)
                await self.emit(sid,'user',text=item.get('text',''),qid=qid)
                try:
                    text,files=await self.execute(sid,principal,item,mid)
                    await self.emit(sid,'assistant',text=text,attachments=files,media_attachments=files,qid=qid)
                    delivery.finish(self.db,sid,mid,'finished')
                    await self.emit(sid,'done',text='completed',qid=qid)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    delivery.finish(self.db,sid,mid,'failed')
                    await self.emit(sid,'error',text=f'Execution failed: {type(exc).__name__}',qid=qid)
                    await self.emit(sid,'done',text='failed',qid=qid)
        finally:
            self.tasks.pop(sid,None)

    async def cleanup(self,app):
        tasks=list(self.tasks.values())
        for task in tasks:task.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)
        for peers in list(self.peers.values()):
            for ws in list(peers):await ws.close(code=1001,message=b'Server stopping')
        self.db.close();self.lock.close()


def configured_service() -> Service:
    return Service(Path(os.environ.get('PA_STATE_DIR','./state')),os.environ.get('PA_ADMIN_TOKEN',''),json.loads(os.environ.get('PA_RUNNER_COMMAND','[]')),float(os.environ.get('PA_RUNNER_TIMEOUT','300')))


async def main():
    os.umask(0o077)
    service=configured_service()
    host=os.environ.get('PA_HOST','127.0.0.1');port=int(os.environ.get('PA_PORT','8080'));upload_port=int(os.environ.get('PA_UPLOAD_PORT',str(port+1000)))
    if not 1<=port<=65535 or not 1<=upload_port<=65535:raise ValueError('Invalid listener port')
    runner=web.AppRunner(service.app,access_log=None)
    await runner.setup()
    try:
        await web.TCPSite(runner,host,port).start()
        if upload_port!=port:await web.TCPSite(runner,host,upload_port).start()
        print('Phone Agent transport ready',flush=True)
        stopped=asyncio.Event();loop=asyncio.get_running_loop()
        for sig in (signal.SIGINT,signal.SIGTERM):loop.add_signal_handler(sig,stopped.set)
        await stopped.wait()
    finally:await runner.cleanup()

if __name__=='__main__':
    try:asyncio.run(main())
    except (ValueError,OSError,json.JSONDecodeError) as exc:
        print(f'Startup refused: {type(exc).__name__}',file=sys.stderr);sys.exit(2)
