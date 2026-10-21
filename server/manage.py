"""Approve a displayed pairing code without putting the administrator token in a URL."""
import argparse,json,os,urllib.request
p=argparse.ArgumentParser();p.add_argument('code');p.add_argument('--origin',default='http://127.0.0.1:8080');a=p.parse_args()
token=os.environ.get('PA_ADMIN_TOKEN','')
if len(token)<24:raise SystemExit('PA_ADMIN_TOKEN must be configured')
req=urllib.request.Request(a.origin.rstrip('/')+'/pair/approve',data=json.dumps({'code':a.code}).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},method='POST')
with urllib.request.urlopen(req,timeout=10) as response:print(response.read().decode())
