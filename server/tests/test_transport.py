"""Real loopback HTTP/WebSocket tests with synthetic native executors, not model-quality tests."""
import asyncio, hashlib, json, os, secrets, sqlite3, sys, tempfile, unittest
from pathlib import Path
from aiohttp import ClientSession, WSServerHandshakeError
from aiohttp.test_utils import TestServer
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from server import Service
import delivery
RUNNER='''import json,os,pathlib,sys,time
r=json.load(sys.stdin)
assert "PA_ADMIN_TOKEN" not in os.environ
p=pathlib.Path("counter.txt");p.write_text(str(int(p.read_text())+1 if p.exists() else 1))
t=r["text"]
if t=="delay":time.sleep(2)
if t=="overflow":print("x"*(1024*1024+20));sys.exit(0)
if t=="bad-path":print(json.dumps({"text":"no","files":["../outside.txt"]}));sys.exit(0)
if t=="symlink":
 pathlib.Path("linked.txt").symlink_to(pathlib.Path("counter.txt"))
 print(json.dumps({"text":"no","files":["linked.txt"]}));sys.exit(0)
pathlib.Path("result.txt").write_text(t)
print(json.dumps({"text":t,"files":["result.txt"]}))
'''
class QueueTests(unittest.TestCase):
 def setUp(self):self.db=sqlite3.connect(':memory:');delivery.initialize(self.db)
 def tearDown(self):self.db.close()
 def test_accept_once(self):
  m='message_identifier_01';a=delivery.accept(self.db,'s',m,1,{'text':'one'});b=delivery.accept(self.db,'s',m,2,{'text':'one'})
  self.assertTrue(a['inserted']);self.assertFalse(b['inserted']);self.assertEqual(b['qid'],1)
 def test_conflict(self):
  m='message_identifier_01';delivery.accept(self.db,'s',m,1,{'text':'one'})
  with self.assertRaises(ValueError):delivery.accept(self.db,'s',m,1,{'text':'two'})
 def test_start_once(self):
  m='message_identifier_01';delivery.accept(self.db,'s',m,1,{'text':'one'})
  self.assertTrue(delivery.start(self.db,'s',m));self.assertFalse(delivery.start(self.db,'s',m))
 def test_restart_does_not_repeat_started(self):
  a='message_identifier_01';b='message_identifier_02';delivery.accept(self.db,'s',a,1,{'text':'one'});delivery.start(self.db,'s',a);delivery.accept(self.db,'s',b,2,{'text':'two'})
  pending,interrupted,qid=delivery.recover(self.db,'s');self.assertEqual([x['client_message_id'] for x in pending],[b]);self.assertEqual(interrupted,[a]);self.assertEqual(qid,2)
 def test_invalid_identifier(self):
  for v in ('../x','short',None,42):
   with self.assertRaises(ValueError):delivery.validate_id(v)
class TransportTests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('PA_TEST_ROOT'));self.root=Path(self.tmp.name);self.script=self.root/'executor.py';self.script.write_text(RUNNER)
  self.token=secrets.token_urlsafe(32);self.s=Service(self.root/'state',self.token,[sys.executable,str(self.script)],timeout=3)
  self.server=TestServer(self.s.app);await self.server.start_server();self.client=ClientSession();self.headers={'Authorization':'Bearer '+self.token};self.sockets=[]
 async def asyncTearDown(self):
  for ws in self.sockets:await ws.close()
  await self.client.close();await self.server.close();self.tmp.cleanup()
 def url(self,p):return self.server.make_url(p)
 async def pair(self):
  r=await self.client.get(self.url('/pair/request'));p=await r.json()
  r=await self.client.post(self.url('/pair/approve'),headers=self.headers,json={'pairing_id':p['pairing_id'],'code':p['code']});self.assertEqual(r.status,200)
  r=await self.client.get(self.url('/pair/poll'),params={'pairing_id':p['pairing_id']});d=await r.json();return {'Authorization':'Bearer '+d['token']},d['device_id']
 async def connect(self,headers=None,sid=None):
  ws=await self.client.ws_connect(self.url('/ws'),headers=headers or self.headers);self.sockets.append(ws);await ws.send_json({'type':'hello','sid':sid,'last_seq':0})
  d=await ws.receive_json(timeout=3);self.assertEqual(d['type'],'session');return ws,d['sid'],d
 async def receive(self,ws,typ):
  for _ in range(40):
   d=await ws.receive_json(timeout=5)
   if d.get('type')==typ:return d
  self.fail('Expected frame absent')
 async def submit(self,ws,sid,text='hello',mid=None):
  mid=mid or 'message_'+secrets.token_hex(12);await ws.send_json({'text':text,'sid':sid,'client_message_id':mid});return mid,await self.receive(ws,'message_ack')
 async def test_unauthenticated_http(self):
  r=await self.client.get(self.url('/healthz'));self.assertEqual(r.status,401)
 async def test_unauthenticated_websocket(self):
  with self.assertRaises(WSServerHandshakeError):await self.client.ws_connect(self.url('/ws'))
 async def test_admin_health(self):
  r=await self.client.get(self.url('/healthz'),headers=self.headers);d=await r.json();self.assertTrue(d['ok']);self.assertFalse(d['capabilities']['incognito'])
 async def test_query_token_cannot_authorize_control(self):
  r=await self.client.get(self.url('/healthz'),params={'token':self.token});self.assertEqual(r.status,401)
 async def test_pair_requires_admin(self):
  r=await self.client.post(self.url('/pair/approve'),json={'code':'invalid'});self.assertEqual(r.status,401)
 async def test_pair_rejects_wrong_code(self):
  r=await self.client.post(self.url('/pair/approve'),headers=self.headers,json={'code':'invalid'});self.assertEqual(r.status,400)
 async def test_device_token_hashed_at_rest(self):
  h,_=await self.pair();r=await self.client.get(self.url('/healthz'),headers=h);self.assertEqual(r.status,200)
  self.assertEqual(self.s.db.execute('SELECT digest FROM devices').fetchone()[0],hashlib.sha256(h['Authorization'][7:].encode()).hexdigest())
 async def test_device_cannot_approve(self):
  h,_=await self.pair();r=await self.client.post(self.url('/pair/approve'),headers=h,json={'code':'invalid'});self.assertEqual(r.status,401)
 async def test_revoke(self):
  h,d=await self.pair();r=await self.client.post(self.url('/pair/revoke'),headers=self.headers,json={'device_id':d});self.assertEqual(r.status,200)
  r=await self.client.get(self.url('/healthz'),headers=h);self.assertEqual(r.status,401)
 async def test_original_delivery_handshake(self):
  _,_,d=await self.connect();self.assertEqual(d['message_delivery'],'message-ack-v1')
 async def test_executor_and_file_roundtrip(self):
  ws,sid,_=await self.connect();mid,ack=await self.submit(ws,sid);self.assertTrue(ack['durable'])
  d=await self.receive(ws,'assistant');await self.receive(ws,'done');self.assertEqual(d['text'],'hello')
  r=await self.client.get(self.url(d['media_attachments'][0]['url']),headers=self.headers);self.assertEqual(await r.read(),b'hello')
  self.assertEqual((self.s.root/'jobs'/sid/mid/'counter.txt').read_text(),'1')
 async def test_duplicate_never_reruns(self):
  ws,sid,_=await self.connect();mid,_=await self.submit(ws,sid);await self.receive(ws,'done');await self.submit(ws,sid,mid=mid);await asyncio.sleep(.05)
  self.assertEqual((self.s.root/'jobs'/sid/mid/'counter.txt').read_text(),'1')
 async def test_changed_duplicate_rejected(self):
  ws,sid,_=await self.connect();mid,_=await self.submit(ws,sid);await self.receive(ws,'done');await ws.send_json({'sid':sid,'client_message_id':mid,'text':'changed'})
  self.assertEqual((await self.receive(ws,'message_rejected'))['client_message_id'],mid)
 async def test_reconnect_replay(self):
  ws,sid,_=await self.connect();await self.submit(ws,sid);await self.receive(ws,'done');await ws.close();ws2,sid2,d=await self.connect(sid=sid)
  self.assertTrue(d['resumed']);self.assertEqual(sid,sid2);self.assertGreater((await self.receive(ws2,'replay_start'))['count'],0);self.assertEqual((await self.receive(ws2,'assistant'))['text'],'hello')
 async def test_cross_device_session_denied(self):
  _,sid,_=await self.connect();h,_=await self.pair();ws=await self.client.ws_connect(self.url('/ws'),headers=h);self.sockets.append(ws);await ws.send_json({'type':'hello','sid':sid});self.assertEqual((await ws.receive_json(timeout=3))['type'],'error')
 async def test_incognito_not_silently_persisted(self):
  ws=await self.client.ws_connect(self.url('/ws'),headers=self.headers);self.sockets.append(ws);await ws.send_json({'type':'hello','incognito':True});self.assertEqual((await ws.receive_json(timeout=3))['type'],'error');self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0],0)
 async def test_upload_roundtrip(self):
  r=await self.client.post(self.url('/upload'),headers={**self.headers,'X-Filename':'sample.txt','X-Mime':'text/plain'},data=b'payload');d=await r.json();self.assertEqual(d['size'],7)
  r=await self.client.get(self.url(d['rel']),headers=self.headers);self.assertEqual(await r.read(),b'payload')
 async def test_upload_unauthorized(self):
  r=await self.client.post(self.url('/upload'),data=b'payload');self.assertEqual(r.status,401)
 async def test_media_query_token(self):
  r=await self.client.post(self.url('/upload'),headers=self.headers,data=b'payload');d=await r.json();r=await self.client.get(self.url(d['rel']),params={'token':self.token});self.assertEqual(await r.read(),b'payload')
 async def test_cross_device_file_denied(self):
  r=await self.client.post(self.url('/upload'),headers=self.headers,data=b'payload');d=await r.json();h,_=await self.pair();r=await self.client.get(self.url(d['rel']),headers=h);self.assertEqual(r.status,404)
 async def test_artifact_path_traversal(self):
  ws,sid,_=await self.connect();await self.submit(ws,sid,'bad-path');await self.receive(ws,'error');self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM files').fetchone()[0],0)
 async def test_artifact_symlink(self):
  ws,sid,_=await self.connect();await self.submit(ws,sid,'symlink');await self.receive(ws,'error');self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM files').fetchone()[0],0)
 async def test_output_limit(self):
  ws,sid,_=await self.connect();await self.submit(ws,sid,'overflow');await self.receive(ws,'error')
 async def test_timeout(self):
  self.s.timeout=.1;ws,sid,_=await self.connect();await self.submit(ws,sid,'delay');await self.receive(ws,'error')
 async def test_text_not_interpreted_as_shell(self):
  ws,sid,_=await self.connect();t='$(touch should-not-exist)';await self.submit(ws,sid,t);self.assertEqual((await self.receive(ws,'assistant'))['text'],t);self.assertFalse(any(self.s.root.rglob('should-not-exist')))
 async def test_missing_token(self):
  with self.assertRaises(ValueError):Service(self.root/'new','',[sys.executable])
 async def test_missing_command(self):
  with self.assertRaises(ValueError):Service(self.root/'new',self.token,[])
 async def test_storage_symlink(self):
  d=self.root/'target';d.mkdir();p=self.root/'link';p.symlink_to(d,target_is_directory=True)
  with self.assertRaises(ValueError):Service(p,self.token,[sys.executable])
 async def test_exclusive_state_owner(self):
  with self.assertRaises(BlockingIOError):Service(self.s.root,self.token,[sys.executable])

 async def test_reset_creates_new_session_without_deleting_history(self):
  ws,sid,_=await self.connect();await self.submit(ws,sid);await self.receive(ws,'done')
  await ws.send_json({'text':'/reset'});d=await self.receive(ws,'session');self.assertNotEqual(d['sid'],sid)
  self.assertGreater(self.s.db.execute('SELECT COUNT(*) FROM frames WHERE sid=?',(sid,)).fetchone()[0],0)
 async def test_revoke_stops_active_executor(self):
  h,device=await self.pair();ws,sid,_=await self.connect(headers=h);await self.submit(ws,sid,'delay')
  for _ in range(50):
   if sid in self.s.processes:break
   await asyncio.sleep(.01)
  r=await self.client.post(self.url('/pair/revoke'),headers=self.headers,json={'device_id':device});self.assertEqual(r.status,200)
  for _ in range(50):
   if sid not in self.s.processes:break
   await asyncio.sleep(.01)
  self.assertNotIn(sid,self.s.processes)
 async def test_service_restart_preserves_session_and_delivery(self):
  ws,sid,_=await self.connect();mid,_=await self.submit(ws,sid);await self.receive(ws,'done');await ws.close()
  await self.server.close()
  self.s=Service(self.root/'state',self.token,[sys.executable,str(self.script)],timeout=3)
  self.server=TestServer(self.s.app);await self.server.start_server()
  ws2,_,d=await self.connect(sid=sid);self.assertTrue(d['resumed']);await self.receive(ws2,'replay_end')
  await self.submit(ws2,sid,mid=mid);await asyncio.sleep(.03)
  self.assertEqual((self.s.root/'jobs'/sid/mid/'counter.txt').read_text(),'1')

if __name__=='__main__':unittest.main(verbosity=2)
