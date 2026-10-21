"""Adapter for a configured native CLI that accepts a prompt on stdin.

The CLI owns the model, tools and agent loop. This adapter only translates the
transport request into a prompt and translates stdout back into a response.
"""
from __future__ import annotations
import asyncio
import json
import os
from pathlib import Path
import sys

async def bounded(reader, limit):
    parts=[];size=0
    while True:
        block=await reader.read(65536)
        if not block:return b''.join(parts)
        size+=len(block)
        if size>limit:raise ValueError('Native CLI output exceeded limit')
        parts.append(block)

async def main():
    command=json.loads(os.environ.get('PA_NATIVE_COMMAND_JSON','[]'))
    if not isinstance(command,list) or not command or not all(isinstance(x,str) and x for x in command):
        raise ValueError('Configure PA_NATIVE_COMMAND_JSON as the native CLI argv array')
    data=sys.stdin.buffer.read(1024*1024+1)
    if len(data)>1024*1024:raise ValueError('Request too large')
    request=json.loads(data)
    prompt='Continue this agent task. Use only tools and permissions configured by the operator.\n'+json.dumps(request,ensure_ascii=False)
    process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        process.stdin.write(prompt.encode());await process.stdin.drain();process.stdin.close()
        text,_=await asyncio.gather(bounded(process.stdout,768*1024),bounded(process.stderr,65536))
        await process.wait()
        if process.returncode:raise ValueError('Native CLI failed')
        # A CLI may explicitly create this bounded artifact manifest in its workspace.
        manifest=Path('artifacts.json')
        files=[]
        if manifest.exists():
            if manifest.is_symlink() or manifest.stat().st_size>65536:raise ValueError('Invalid artifact manifest')
            files=json.loads(manifest.read_text())
            if not isinstance(files,list):raise ValueError('Artifact manifest must be a list')
        print(json.dumps({'text':text.decode('utf-8',errors='replace'),'files':files},ensure_ascii=False))
    finally:
        if process.returncode is None:
            process.kill();await process.wait()

if __name__=='__main__':
    try:asyncio.run(main())
    except Exception as exc:
        print('Executor adapter failed: '+type(exc).__name__,file=sys.stderr);sys.exit(2)
