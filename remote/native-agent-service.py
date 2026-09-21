#!/usr/bin/env python3
"""SSH-only loopback broker. Owns Agent stdin independently of any Mac client."""
import argparse, base64, copy, fcntl, hashlib, hmac, json, os, pathlib, secrets, shutil, subprocess, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
ROOT = pathlib.Path(os.environ.get('AWB_NATIVE_ROOT', '~/.local/share/agent-workbench/native')).expanduser()
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
ROOT.chmod(0o700)
os.umask(0o077)
LOCK = threading.RLock()
SESSIONS = {}
MODELS = None
MODEL_LOCK = threading.Lock()
DSH_MODELS = None

def model_catalog():
    global MODELS
    # CLI discovery must not hold the lock used by streaming, approvals and abort.
    with MODEL_LOCK:
        if MODELS is None:
            out=subprocess.run(['omp','models','--json','--no-extensions'],capture_output=True,text=True,timeout=60)
            if out.returncode!=0: raise ValueError('读取 omp 模型列表失败：'+(out.stderr or '').strip()[:200])
            MODELS=json.loads(out.stdout)
        return MODELS

def dsh_binary():
    if os.environ.get('DSH_BIN'): return os.environ['DSH_BIN']
    marker = ROOT / 'dsh-runtime'
    if marker.exists():
        path = marker.read_text().strip()
        if path and os.path.exists(path): return path
    found = shutil.which('dsh')
    if found: return found
    raise ValueError('未找到 dsh 运行时：重跑 install-native-service.sh --with-dsh，或把 dsh 加入 PATH（也可设 DSH_BIN）')

def dsh_catalog_update(config_options):
    # The Mac picker consumes one normalized shape; dsh reports its live catalog as
    # ACP config options, so conversion happens here once rather than on the client.
    global DSH_MODELS
    model_option = next((o for o in config_options if o.get('id') == 'model'), None)
    if not model_option: return
    effort = next((o for o in config_options if o.get('id') == 'reasoning_effort'), {})
    efforts = [e['value'] for e in effort.get('options', []) if e.get('value')]
    current = model_option.get('currentValue')
    entries = []
    for group in model_option.get('options', []):
        for item in group.get('options', []):
            try: provider, model = json.loads(item['value'])
            except Exception: continue
            entries.append({'id': model, 'provider': provider, 'name': item.get('name') or model,
                            'thinking': efforts if item.get('value') == current else []})
    DSH_MODELS = entries
    save(ROOT / 'dsh-catalog.json', entries)

def dsh_catalog():
    global DSH_MODELS
    if DSH_MODELS is None:
        path = ROOT / 'dsh-catalog.json'
        if path.exists(): DSH_MODELS = json.loads(path.read_text())
    return DSH_MODELS or []

def catalog_entries(value, agent):
    # `omp models --json` answers {"models":[...]} (ModelsJson in 18.1.16), older
    # builds answer a bare list, and a stale dsh cache answers whatever it holds.
    # The Mac side already tolerates every shape, so the bridge must too: reading
    # only the list form served an empty OMP catalog and an empty picker.
    if isinstance(value, dict):
        value = next((value[name] for name in ('models', 'items') if isinstance(value.get(name), list)), [])
    if not isinstance(value, list): return []
    return [dict(e, agent=agent) for e in value if isinstance(e, dict)]

def combined_catalog():
    # One list serves every native runtime, so each entry names the runtime that can
    # actually route it. Without that tag the Mac picker cannot tell an OMP model
    # from a dsh one, and a dsh route handed to `omp --model` just fails.
    dsh = catalog_entries(dsh_catalog(), 'dsh')
    try: omp = catalog_entries(model_catalog(), 'omp')
    except Exception:
        if dsh: return dsh
        raise
    return omp + dsh

def save(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False)); tmp.replace(path)

def text_parts(content):
    if isinstance(content, str): return [{'type':'text','text':content}]
    return content or []

def normalize(message, identity):
    role = message.get('role', 'assistant'); content = text_parts(message.get('content'))
    if role == 'toolResult':
        return {'id':identity,'role':'tool','created_at':str(message.get('timestamp', '')), 'content':[{'type':'tool_result','tool_call_id':message.get('toolCallId'), 'output':content, 'is_error':message.get('isError',False)}]}
    parts = []
    for p in content:
        kind = p.get('type')
        if kind in ('text','thinking'): parts.append({'type':kind, kind:p.get(kind,'')})
        elif kind in ('toolCall','tool_use'): parts.append({'type':'tool_use','tool_call_id':p.get('id'),'tool_name':p.get('name'),'input':p.get('arguments',p.get('input',{}))})
        elif kind == 'tool_result': parts.append({'type':kind,'tool_call_id':p.get('tool_use_id'),'output':p.get('content'),'is_error':p.get('is_error',False)})
    return {'id':identity,'role':role,'content':parts,'created_at':str(message.get('timestamp',''))}

class Session:
    def __init__(self, state):
        self.state = state; self.process = None; self.write_lock = threading.Lock(); self.last_save = 0; self.deleted = False
        self.path = ROOT / 'sessions' / (state['id'] + '.json')
        self.ready = threading.Event(); self.chunks = None; self.command_id = None
        # dsh (ACP) runtime-only state: wire request routing, the prompt waiting for
        # the handshake, per-message block assembly and pending permission options.
        self.acp_pending = {}; self.acp_next_id = 0; self.pending_prompt = None
        self.acp_blocks = {}; self.permission_options = {}
        # Version 1 stored command results as plain strings in existing histories.
        previous=state.get('commandResult')
        if isinstance(previous,str):
            state['commandResult']={'id':'restored-command','status':'completed' if previous=='已完成' else 'unknown',
                                    'error':None if previous=='已完成' else '此前命令结果：'+previous}
    def persist(self):
        self.path.parent.mkdir(exist_ok=True); save(self.path, self.state); self.last_save = time.monotonic()
    def touch(self, durable=False):
        self.state['revision'] += 1
        if durable or time.monotonic()-self.last_save > 1: self.persist()
    def summary(self):
        return {k:self.state[k] for k in ('id','provider','title','cwd','busy','archived','updated','revision','completed','model','error')} | {
            'pending':len(self.state['interactions']), 'cancelled':self.state.get('cancelled',False),
            'thinking':self.state.get('thinking'), 'context':self.state.get('context'),
            'turnId':self.state.get('turnId'), 'turnState':self.state.get('turnState'),
            'steer':self.state['provider']=='omp'}
    def finish(self, status):
        self.state['turnState']=status
        receipt=self.state.get('requests',{}).get(self.state.get('turnId'))
        if receipt:
            receipt['status']=status
            receipt['error']=self.state.get('error')
    def prompt(self, body):
        s=self.state; request_id=body.get('requestId')
        if not isinstance(request_id,str) or not request_id: raise ValueError('缺少 requestId，请更新客户端')
        text=body['text']; digest=hashlib.sha256(text.encode()).hexdigest()
        receipts=s.setdefault('requests',{})
        if request_id in receipts:
            receipt=receipts[request_id]
            if receipt['digest']!=digest: raise ValueError('requestId 已用于另一条消息')
            return copy.deepcopy(receipt)
        if s['busy'] or s['archived']: raise ValueError('会话正在运行或已归档')
        if not text.strip(): raise ValueError('消息不能为空')
        if not self.process or self.process.poll() is not None: self.launch()
        receipt={'id':request_id,'digest':digest,'text':text,'status':'submitting'}
        receipts[request_id]=receipt
        s.update(busy=True,error=None,cancelled=False,stopRequested=False,stopAcknowledged=False,
                 updated=time.time(),turnId=request_id,turnState='submitting')
        if not s['messages']: s['title']=text[:60]
        if s['provider']=='qoder' or s['provider']=='dsh': self.upsert({'role':'user','content':text},request_id)
        if s['provider']=='dsh':
            # ACP needs initialize + session/new|resume before the first prompt; the
            # read thread flushes this once the handshake lands.
            self.pending_prompt=(request_id,text)
            try:
                if self.ready.is_set(): self.acp_flush_prompt()
            except Exception as e:
                # The write may or may not have landed; never claim submission.
                s['busy']=False; s['error']=str(e); self.finish('unknown')
            self.touch(True)
            return copy.deepcopy(receipt)
        # Persist before writing: a service crash between disk and stdin leaves an
        # unknown outcome, never permission to execute the instruction a second time.
        self.touch(True)
        try:
            self.send({'type':'prompt','id':request_id,'message':text})
            receipt['status']='submitted'; s['turnState']='submitted'
        except Exception as e:
            s['busy']=False; s['error']=str(e); self.finish('unknown')
        self.touch(True)
        return copy.deepcopy(receipt)
    def launch(self):
        s = self.state
        env = None
        if s['provider'] == 'omp':
            args = ['omp','--mode','rpc-ui','--cwd',s['cwd'],'--approval-mode','always-ask','--no-title','--session-dir',str(ROOT/'omp-sessions')]
            if s.get('resume'): args += ['--resume',s['resume']]
            if s['model']: args += ['--model',s['model']]
            if s.get('thinking'): args += ['--thinking',s['thinking']]
        elif s['provider'] == 'dsh':
            args = [dsh_binary(),'--profile','acp']
            # A dedicated home keeps workbench sessions out of the user's own ~/.dsh,
            # and telemetry stays off unless the user turns it on themselves.
            env = dict(os.environ, DSH_HOME=str(ROOT/'dsh-home'), DSH_TELEMETRY_MODE='DISABLED')
        else:
            cfg = {'cwd':s['cwd'],'model':s['model'],'resume':s.get('resume'),'binary':shutil.which('qoderclicn')}
            if not cfg['binary']: raise ValueError('未找到 qoderclicn')
            args = ['node',str(ROOT/'qoder-worker.mjs'),json.dumps(cfg)]
        self.ready.clear()
        self.acp_pending = {}; self.acp_next_id = 0; self.pending_prompt = None
        self.acp_blocks = {}; self.permission_options = {}
        self.process = subprocess.Popen(args,cwd=s['cwd'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(ROOT/(s['id']+'.stderr'),'a'),text=True,start_new_session=True,env=env)
        threading.Thread(target=self.read,daemon=True).start()
        if s['provider'] == 'dsh':
            # The handshake is asynchronous; the prompt stays parked in
            # pending_prompt until session/new|resume answers.
            self.acp_request('initialize', {'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False}}}, 'initialize')
    def send(self, value):
        if not self.process or self.process.poll() is not None: raise ValueError('远端进程已退出，请重新发送以恢复会话')
        with self.write_lock:
            self.process.stdin.write(json.dumps(value,ensure_ascii=False)+'\n'); self.process.stdin.flush()
    def acp_request(self, method, params, kind):
        self.acp_next_id += 1
        request_id = self.acp_next_id
        self.acp_pending[request_id] = kind
        self.send({'jsonrpc':'2.0','id':request_id,'method':method,'params':params})
        return request_id
    def acp_notify(self, method, params):
        self.send({'jsonrpc':'2.0','method':method,'params':params})
    def acp_flush_prompt(self):
        # session/prompt settles only when the whole turn does, so its response — not
        # a separate event — is the turn's terminal signal.
        if not self.pending_prompt: return
        request_id, text = self.pending_prompt
        self.pending_prompt = None
        self.acp_request('session/prompt', {'sessionId':self.state['resume'],'prompt':[{'type':'text','text':text}]}, 'prompt:'+request_id)
        receipt = self.state.get('requests',{}).get(request_id)
        if receipt and receipt['status'] == 'submitting':
            receipt['status'] = 'submitted'
            if self.state.get('turnState') == 'submitting': self.state['turnState'] = 'submitted'
    def acp_apply_options(self, options):
        s = self.state
        s['acpOptions'] = options
        dsh_catalog_update(options)
        model_option = next((o for o in options if o.get('id') == 'model'), None)
        if model_option and model_option.get('currentValue'):
            try:
                provider, model = json.loads(model_option['currentValue'])
                s['model'] = model; s['provider_id'] = provider
            except Exception: pass
        effort = next((o for o in options if o.get('id') == 'reasoning_effort'), None)
        if effort is not None:
            # The empty value is "provider default", which is a real choice, not an
            # unknown level; keep it distinct from a named effort.
            s['thinking'] = effort.get('currentValue') or None
    def acp_event(self, frame):
        # Fold the ACP wire shape into the per-provider event vocabulary event()
        # already switches on. Unknown frames are dropped rather than failing the
        # stream, because dsh is a preview runtime that may add message kinds.
        if 'method' in frame and 'id' in frame:
            return {'type':'acp_request','wireId':frame['id'],'method':frame['method'],'params':frame.get('params') or {}}
        if 'method' in frame:
            return {'type':'acp_notification','method':frame['method'],'params':frame.get('params') or {}}
        if 'id' in frame:
            kind = self.acp_pending.pop(frame['id'], 'unknown')
            return {'type':'acp_response','kind':kind,'result':frame.get('result'),'error':frame.get('error')}
        return None
    def acp_fail_prompt(self, message):
        self.pending_prompt = None
        self.state['busy'] = False; self.state['error'] = message
        self.finish('failed'); self.touch(True)
    def acp_sync_config(self):
        # Apply the workbench-side model/thinking wishes after (re)opening, then let
        # the parked prompt go. Each step waits for the runtime's answer so a prompt
        # never gets pinned to a route the user already replaced.
        s = self.state
        options = s.get('acpOptions') or []
        model_option = next((o for o in options if o.get('id') == 'model'), None)
        if s.get('model') and model_option and model_option.get('currentValue'):
            try: current = json.loads(model_option['currentValue'])[1]
            except Exception: current = None
            if current and s['model'] != current:
                target = None
                for group in model_option.get('options', []):
                    for item in group.get('options', []):
                        try:
                            if json.loads(item['value'])[1] == s['model']: target = target or item['value']
                        except Exception: pass
                if target:
                    self.acp_request('session/set_config_option', {'sessionId':s['resume'],'configId':'model','value':target}, 'set_config')
                    return
                s['error'] = 'dsh 不认识模型 %s，沿用当前模型' % s['model']
        effort = next((o for o in options if o.get('id') == 'reasoning_effort'), None)
        if s.get('thinking') and effort is not None:
            values = [o.get('value') for o in effort.get('options', [])]
            if s['thinking'] != effort.get('currentValue') and s['thinking'] in values:
                self.acp_request('session/set_config_option', {'sessionId':s['resume'],'configId':'reasoning_effort','value':s['thinking']}, 'set_config')
                return
        self.acp_flush_prompt()
    def acp_update(self, update):
        s = self.state
        kind = update.get('sessionUpdate')
        if s['busy'] and s.get('turnState') in ('submitting','submitted','accepted'):
            self.finish('running')
        if kind in ('agent_message_chunk', 'agent_thought_chunk'):
            message_id = update.get('messageId') or 'live'
            blocks = self.acp_blocks.setdefault(message_id, [])
            content = update.get('content') or {}
            if kind == 'agent_thought_chunk':
                blocks.append({'type':'thinking','thinking':content.get('text','')})
            elif content.get('type') == 'text':
                blocks.append({'type':'text','text':content.get('text','')})
            elif content.get('type') == 'resource_link':
                blocks.append({'type':'text','text':'[%s](%s)' % (content.get('name') or content.get('uri') or '资源', content.get('uri') or '')})
            else:
                blocks.append({'type':'text','text':'[dsh 发出了暂不支持的内容类型 %s]' % content.get('type')})
            self.upsert({'role':'assistant','content':list(blocks),'timestamp':time.time()}, 'dsh:'+message_id)
            return True
        if kind == 'tool_call':
            self.upsert({'role':'assistant','content':[{'type':'toolCall','id':update.get('toolCallId'),'name':update.get('title') or 'tool','arguments':update.get('rawInput') if update.get('rawInput') is not None else {}}],'timestamp':time.time()}, 'dsh-tool:'+str(update.get('toolCallId')))
            return True
        if kind == 'tool_call_update':
            texts = []
            for part in update.get('content') or []:
                body = part.get('content') or {}
                if body.get('type') == 'text' and body.get('text'): texts.append(body['text'])
            self.upsert({'role':'toolResult','toolCallId':update.get('toolCallId'),'content':'\n'.join(texts),'isError':update.get('status') == 'failed','timestamp':time.time()}, 'dsh-result:'+str(update.get('toolCallId')))
            return True
        if kind == 'usage_update':
            s['context'] = {'tokens':update.get('used'),'limit':update.get('size')}
            return True
        if kind == 'config_option_update' and update.get('configOptions'):
            self.acp_apply_options(update['configOptions'])
            return True
        return False
    def read(self):
        try:
            for line in self.process.stdout:
                event = json.loads(line)
                if self.state['provider'] == 'dsh': event = self.acp_event(event)
                if event is None: continue
                if event.get('type') == 'rpc_chunk':
                    if event['index'] == 0: self.chunks = {'id':event['chunkId'],'count':event['count'],'size':event['byteLength'],'parts':[]}
                    c = self.chunks
                    if not c or c['size'] > 67108864 or event['chunkId'] != c['id'] or event['index'] != len(c['parts']) or event['count'] != c['count']: raise ValueError('OMP 分块协议错误')
                    c['parts'].append(base64.b64decode(event['data'],validate=True))
                    if len(c['parts']) != c['count']: continue
                    raw = b''.join(c['parts']); self.chunks = None
                    if len(raw) != c['size']: raise ValueError('OMP 分块长度错误')
                    event = json.loads(raw)
                elif self.chunks: raise ValueError('OMP 分块被中断')
                with LOCK: self.event(event)
        except Exception as e:
            with LOCK: self.state['error'] = str(e)
        finally:
            with LOCK:
                if self.deleted: return
                if self.state['busy']: self.state['error'] = self.state['error'] or '远端进程退出，任务未完成；可重新发送继续历史'
                if self.state['busy']: self.finish('unknown')
                self.state['busy'] = False; self.state['interactions'] = []; self.touch(True)
    def upsert(self, message, identity):
        value = normalize(message,identity)
        for i, existing in enumerate(self.state['messages']):
            if existing['id'] == identity: self.state['messages'][i] = value; return
        self.state['messages'].append(value)
    def steer(self, body):
        s=self.state; request_id=body.get('requestId'); text=body.get('text','')
        if s['provider']!='omp': raise ValueError('当前 Agent 不支持运行中引导')
        if not isinstance(request_id,str) or not request_id or not text.strip():
            raise ValueError('缺少 requestId 或消息内容')
        receipts=s.setdefault('requests',{}); digest=hashlib.sha256(text.encode()).hexdigest()
        if request_id in receipts:
            receipt=receipts[request_id]
            if receipt['digest']!=digest: raise ValueError('requestId 已用于另一条消息')
            return copy.deepcopy(receipt)
        # The turn can finish between the client's snapshot and this request.
        if not s['busy']: return self.prompt(body)
        if s.get('stopRequested'): raise ValueError('正在停止，请等待停止完成')
        receipt={'id':request_id,'digest':digest,'text':text,'status':'submitted',
                 'mode':'steer','turnId':s.get('turnId')}
        receipts[request_id]=receipt
        self.touch(True)
        try: self.send({'type':'steer','id':request_id,'message':text})
        except Exception as e: receipt.update(status='unknown',error=str(e))
        self.touch(True)
        return copy.deepcopy(receipt)

    def event(self,e):
        s = self.state; t = e.get('type'); provider = s['provider']; durable = False
        if t == 'ready':
            self.ready.set()
            if provider == 'omp':
                self.send({'id':'protocol','type':'negotiate_protocol','protocolVersion':2})
                self.send({'id':'state','type':'get_state'})
            return
        if t == 'response':
            receipt=s.get('requests',{}).get(e.get('id'))
            if e.get('command')=='steer' and receipt and receipt.get('mode')=='steer':
                # A late ack must not overwrite evidence that the model consumed it.
                if receipt['status']=='submitted':
                    receipt.update(status='accepted' if e.get('success') else 'failed',
                                   error=None if e.get('success') else str(e.get('error','引导被拒绝')))
                    self.touch(True)
                return
            # A command reporting "nothing to compact" describes that command, not a
            # broken session, so it must not mark the session as errored.
            if self.command_id and e.get('id') == self.command_id:
                self.command_id = None
                s['commandResult'] = {'id':e['id'],'status':'completed' if e.get('success') else 'failed',
                                      'error':None if e.get('success') else str(e.get('error','命令执行失败'))}
                self.touch(True); return
            if e.get('id')==s.get('turnId') and e.get('command')=='prompt' and not e.get('success'):
                s['error']=str(e.get('error','RPC 拒绝消息')); s['busy']=False
                self.finish('failed'); self.touch(True); return
            if e.get('id')==s.get('turnId') and e.get('command')=='prompt' and e.get('success'):
                if s.get('turnState')=='submitted': self.finish('accepted'); self.touch(True)
                return
            if not e.get('success'): s['error'] = str(e.get('error','RPC 请求失败'))
            if e.get('command') == 'get_state' and e.get('success'):
                d=e['data']; s['resume']=d.get('sessionFile')
                m=d.get('model') or {}
                s['model']=m.get('id',s['model']); s['provider_id']=m.get('provider')
                s['thinking']=d.get('thinkingLevel')
                # Only the runtime knows the live window; absent usage stays absent so
                # the client can show "unknown" instead of a full context bar.
                u=d.get('contextUsage') or {}
                s['context']={'tokens':u.get('tokens'),'limit':u.get('contextWindow')} if u.get('contextWindow') else None
                durable=True
            else: return
        elif t == 'agent_start':
            s['busy']=True; s['error']=None; s['updated']=time.time(); self.finish('running'); durable=True
        elif t == 'stop_ack' and e.get('turnId')==s.get('turnId'):
            s['stopAcknowledged']=True; durable=True
        elif t == 'agent_end':
            if e.get('isTerminal') is False: return
            if provider=='qoder' and s.get('stopAcknowledged'): s['cancelled']=True
            s['busy']=False; s['interactions']=[]; s['updated']=time.time(); durable=True
            if not s.get('cancelled') and not s['error']: s['completed']+=1
            self.finish('stopped' if s.get('cancelled') else 'failed' if s['error'] else 'completed')
            for receipt in s.get('requests',{}).values():
                if receipt.get('mode')=='steer' and receipt.get('turnId')==s.get('turnId') and receipt['status'] in ('submitted','accepted'):
                    receipt.update(status='unknown',error='本轮已结束，尚未观察到引导消息进入上下文')
            if e.get('resume'): s['resume']=e['resume']
            # Context usage only moves when a turn consumes tokens, so re-read it here
            # rather than polling get_state on a timer.
            if provider == 'omp':
                try: self.send({'id':'state','type':'get_state'})
                except Exception: pass
        elif t in ('worker_error','extension_error'):
            s['error']=None if s.get('cancelled') or s.get('stopAcknowledged') else e.get('message',e.get('error','Agent 错误')); durable=True
        elif provider == 'omp' and t in ('message_start','message_update','message_end'):
            m=e['message']; identity=str(m.get('timestamp'))+':'+m['role']
            if m['role']=='user':
                # Bind the runtime's echo to the submitted id, including repeated text.
                receipts=s.get('requests',{})
                receipt=next((r for r in receipts.values() if r.get('runtimeId')==identity),None)
                if receipt is None:
                    content=m.get('content',[])
                    text=content if isinstance(content,str) else ''.join(p.get('text','') for p in content if p.get('type')=='text')
                    receipt=next((r for r in receipts.values() if r.get('text')==text
                                  and not r.get('runtimeId') and r['status'] in ('submitting','submitted','accepted','running','unknown')),None)
                if receipt:
                    receipt['runtimeId']=identity; identity=receipt['id']
                    if receipt.get('mode')=='steer': receipt.update(status='consumed',error=None)
            self.upsert(m,identity); durable=t=='message_end'
            if m.get('stopReason')=='aborted': s['cancelled']=True
            if m.get('stopReason')=='error': s['error']=m.get('errorMessage','模型请求失败')
        elif provider == 'omp' and t == 'extension_ui_request':
            method=e.get('method')
            if method == 'cancel': s['interactions']=[x for x in s['interactions'] if x['id']!=e['id']]
            elif method in ('confirm','select','input','editor'):
                s['interactions'].append(e | {'expires':time.time()+e['timeout']/1000 if e.get('timeout') else None})
            elif method == 'notify' and e.get('notifyType')=='error': s['error']=e.get('message')
            else: return
            durable=True
        elif provider == 'omp' and t == 'available_commands_update':
            # The runtime is the only authority on which commands this session has,
            # and it re-sends the whole list as extensions mount, so an unchanged
            # list must not bump the revision the Mac polls on.
            commands=[c for c in (e.get('commands') or []) if c.get('name')]
            if commands == s.get('commands'): return
            s['commands']=commands
        elif provider == 'qoder' and t == 'interaction': s['interactions'].append(e); durable=True
        elif provider == 'qoder' and t == 'interaction_cancel': s['interactions']=[x for x in s['interactions'] if x['id']!=e['id']]; durable=True
        elif provider == 'qoder' and t in ('assistant','user'):
            self.upsert(e['message'], e.get('uuid') or e['message'].get('id') or str(uuid.uuid4())); s.pop('partial',None); durable=True
        elif provider == 'qoder' and t == 'stream_event':
            ev=e['event']; et=ev['type']
            if et=='message_start': s['partial']={'role':'assistant','content':[]}
            elif et=='content_block_start':
                s.setdefault('partial',{'role':'assistant','content':[]})['content'].append(ev['content_block'])
            elif et=='content_block_delta' and s.get('partial'):
                idx=ev['index']; delta=ev['delta']; parts=s['partial']['content']
                if idx<len(parts):
                    if delta['type']=='text_delta': parts[idx]['text']=parts[idx].get('text','')+delta['text']
                    elif delta['type']=='thinking_delta': parts[idx]['thinking']=parts[idx].get('thinking','')+delta['thinking']
            else: return
        elif provider == 'qoder' and t == 'result':
            s['resume']=e.get('session_id',s.get('resume')); durable=True
            if e.get('is_error') and not s.get('cancelled') and not s.get('stopAcknowledged'): s['error']='\n'.join(e.get('errors',[])) or e.get('result','Qoder 执行失败')
        elif provider == 'qoder' and t == 'system' and e.get('subtype')=='init': s['resume']=e.get('session_id'); s['model']=e.get('model',s['model']); durable=True
        elif provider == 'dsh' and t == 'acp_response' and e['kind'] == 'initialize':
            if e.get('error'):
                s['error']='dsh 握手失败：'+str(e['error'].get('message','initialize 被拒绝'))
                if self.pending_prompt: self.acp_fail_prompt(str(e['error'].get('message','握手失败')))
                durable=True
            else:
                if s.get('resume'):
                    self.acp_request('session/resume', {'sessionId':s['resume'],'cwd':s['cwd']}, 'session_open')
                else:
                    self.acp_request('session/new', {'cwd':s['cwd'],'mcpServers':[]}, 'session_open')
            return
        elif provider == 'dsh' and t == 'acp_response' and e['kind'] == 'session_open':
            if e.get('error'):
                s['error']='dsh 会话打开失败：'+str(e['error'].get('message','未知错误'))
                if self.pending_prompt: self.acp_fail_prompt(s['error'])
            else:
                result = e.get('result') or {}
                if result.get('sessionId'): s['resume'] = result['sessionId']
                self.acp_apply_options(result.get('configOptions') or [])
                self.ready.set()
                self.acp_sync_config()
            durable=True
        elif provider == 'dsh' and t == 'acp_response' and e['kind'] == 'set_config':
            if e.get('error'):
                s['error']='dsh 设置被拒绝：'+str(e['error'].get('message','未知错误'))
            else:
                self.acp_apply_options((e.get('result') or {}).get('configOptions') or [])
                self.acp_sync_config()
            durable=True
        elif provider == 'dsh' and t == 'acp_response' and e['kind'].startswith('prompt:'):
            s['busy']=False; s['interactions']=[]; s['updated']=time.time(); durable=True
            if e.get('error'):
                message=str(e['error'].get('message','dsh 执行失败'))
                if message.startswith('Internal error: '): message=message[len('Internal error: '):]
                # The cancel ack for dsh IS the prompt response; an error racing a
                # requested stop reads as a stopped turn, not as a failure.
                if s.get('stopRequested'): s['cancelled']=True
                elif not s.get('cancelled'): s['error']=message
            elif (e.get('result') or {}).get('stopReason') == 'cancelled':
                s['cancelled']=True
            if s.get('cancelled'): s['stopAcknowledged']=True
            if not s.get('cancelled') and not s['error']: s['completed']+=1
            self.finish('stopped' if s.get('cancelled') else 'failed' if s['error'] else 'completed')
        elif provider == 'dsh' and t == 'acp_notification' and e['method'] == 'session/update':
            if (e['params'].get('sessionId')) != s.get('resume'): return
            durable = self.acp_update(e['params'].get('update') or {})
            if not durable: return
        elif provider == 'dsh' and t == 'acp_request' and e['method'] == 'session/request_permission':
            if (e['params'].get('sessionId')) != s.get('resume'):
                try: self.send({'jsonrpc':'2.0','id':e['wireId'],'result':{'outcome':{'outcome':'cancelled'}}})
                except Exception: pass
                return
            labels = []; mapping = {}
            for i, option in enumerate(e['params'].get('options') or []):
                label = option.get('name') or option.get('kind') or str(option.get('optionId'))
                if label in mapping: label = '%s (%d)' % (label, i+1)
                mapping[label] = option.get('optionId'); labels.append(label)
            interaction_id = 'acp-permission-' + str(e['wireId'])
            self.permission_options[interaction_id] = {'wireId':e['wireId'],'map':mapping}
            tool = e['params'].get('toolCall') or {}
            preview = None
            if tool.get('rawInput') is not None:
                preview = json.dumps(tool['rawInput'], ensure_ascii=False)
                if len(preview) > 400: preview = preview[:400] + '…'
            s['interactions'].append({'id':interaction_id,'method':'select','title':tool.get('title') or '工具审批','message':preview,'options':labels})
            durable=True
        elif provider == 'dsh' and t == 'acp_request':
            # A server->client request this bridge does not understand must still be
            # answered, or the agent wedges waiting on a decision slot.
            try: self.send({'jsonrpc':'2.0','id':e['wireId'],'error':{'code':-32601,'message':'unsupported by the workbench bridge'}})
            except Exception: pass
            return
        else: return
        self.touch(durable)
    def snapshot(self, revision=None):
        live=[x for x in self.state['interactions'] if not x.get('expires') or x['expires']>time.time()]
        if live != self.state['interactions']: self.state['interactions']=live; self.touch(True)
        if revision == str(self.state['revision']): return {'unchanged':True}
        # Idempotency receipts are queried individually; do not resend/copy the
        # entire receipt ledger with each streaming transcript snapshot.
        s=copy.deepcopy({k:v for k,v in self.state.items() if k!='requests'})
        if s.get('partial'): s['messages'].append(normalize(s.pop('partial'),'live'))
        return s

def load():
    for path in (ROOT/'sessions').glob('*.json'):
        s=json.loads(path.read_text())
        if s['busy']: s['error']='托管服务曾中断，任务未完成；发送新消息以恢复历史'
        s['busy']=False; s['interactions']=[]; s['revision']+=1
        restored=Session(s); restored.persist(); SESSIONS[s['id']]=restored
        for receipt in s.get('requests',{}).values():
            if receipt['status'] in ('submitting','submitted','accepted','running'): receipt['status']='unknown'
        if s.get('turnState') in ('submitting','submitted','accepted','running'): restored.finish('unknown')
        if isinstance(s.get('commandResult'),dict) and s['commandResult'].get('status')=='running':
            s['commandResult'].update(status='unknown',error='服务曾中断，命令结果未知')
        restored.persist()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self): self.handle_request(False)
    def do_POST(self): self.handle_request(True)
    def handle_request(self,post):
        if not hmac.compare_digest(self.headers.get('Authorization',''), 'Bearer '+TOKEN): return self.respond(401,{'error':'Unauthorized'})
        try:
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}') if post else {}
            path=urlparse(self.path).path.split('/')
            if self.path=='/models' and not post:
                return self.respond(200,{'models':combined_catalog()})
            with LOCK:
                if self.path=='/health': result={'version':2}
                elif self.path=='/sessions' and not post: result={'sessions':[s.summary() for s in SESSIONS.values()]}
                elif self.path=='/sessions' and post:
                    if body['provider'] not in ('omp','qoder','dsh') or not os.path.isabs(body['cwd']) or not os.path.isdir(body['cwd']): raise ValueError('请选择有效的远端绝对目录')
                    sid=str(uuid.uuid4()); s=Session({'id':sid,'provider':body['provider'],'title':body.get('title') or '新对话','cwd':body['cwd'],'model':body.get('model',''),'busy':False,'archived':False,'updated':time.time(),'revision':0,'completed':0,'messages':[],'interactions':[],'error':None})
                    s.persist(); SESSIONS[sid]=s
                    if body['provider']=='dsh':
                        # Launch at create so the ACP handshake lands before the first
                        # prompt and the model picker has a live catalog to show.
                        try: s.launch()
                        except Exception as e: s.state['error']=str(e); s.touch(True)
                    result=s.summary()
                elif len(path)>=3 and path[1]=='sessions':
                    s=SESSIONS[path[2]]
                    if not post and len(path)==5 and path[3]=='requests':
                        result=copy.deepcopy(s.state.get('requests',{}).get(path[4],{'id':path[4],'status':'notFound'}))
                    elif not post:
                        since=parse_qs(urlparse(self.path).query).get('revision',[None])[0]
                        result=s.snapshot(since)
                    else:
                        action=path[3]
                        if action=='prompt':
                            result=s.prompt(body)
                        elif action=='steer':
                            result=s.steer(body)
                        elif action=='model':
                            if s.state['provider'] not in ('omp','dsh'): raise ValueError('当前 Agent 不支持切换模型')
                            if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                            provider,model=body.get('provider',''),body.get('model','')
                            if not provider or not model: raise ValueError('请同时指定 provider 和模型')
                            if s.state['provider']=='dsh':
                                # Send the runtime's own opaque option value back rather
                                # than re-serializing [provider, model] ourselves.
                                options = s.state.get('acpOptions') or []
                                model_option = next((o for o in options if o.get('id')=='model'), {})
                                target = next((item['value'] for group in model_option.get('options',[]) for item in group.get('options',[]) if item.get('value')==json.dumps([provider,model],separators=(',',':')) or item.get('value')==json.dumps([provider,model])), None)
                                if target is None: raise ValueError('dsh 不认识该模型，请同步后重试')
                                if s.process and s.process.poll() is None and s.ready.is_set():
                                    s.acp_request('session/set_config_option', {'sessionId':s.state.get('resume'),'configId':'model','value':target}, 'set_config')
                                else:
                                    # Applied by acp_sync_config on the next handshake.
                                    s.state['model']=model; s.state['provider_id']=provider; s.touch(True)
                                result={'ok':True}
                            else:
                                # set_model takes provider and modelId separately; a combined
                                # "provider/id" string is rejected by the runtime.
                                if s.process and s.process.poll() is None:
                                    s.send({'id':str(uuid.uuid4()),'type':'set_model','provider':provider,'modelId':model})
                                    s.send({'id':'state','type':'get_state'})
                                s.state['model']=model; s.state['provider_id']=provider; s.touch(True)
                        elif action=='thinking':
                            if s.state['provider'] not in ('omp','dsh'): raise ValueError('当前 Agent 不支持设置思考强度')
                            level=body.get('level','')
                            if not level: raise ValueError('请指定思考强度')
                            if s.state['provider']=='dsh':
                                if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                                options = s.state.get('acpOptions') or []
                                effort = next((o for o in options if o.get('id')=='reasoning_effort'), {})
                                values = [o.get('value') for o in effort.get('options',[])]
                                if values and level not in values: raise ValueError('当前模型不支持该思考强度')
                                if s.process and s.process.poll() is None and s.ready.is_set():
                                    s.acp_request('session/set_config_option', {'sessionId':s.state.get('resume'),'configId':'reasoning_effort','value':level}, 'set_config')
                                else:
                                    s.state['thinking']=level; s.touch(True)
                                result={'ok':True}
                            else:
                                # The runtime answers success for an unknown level and then
                                # reports null, so the caller must have validated it already.
                                if s.process and s.process.poll() is None:
                                    s.send({'id':str(uuid.uuid4()),'type':'set_thinking_level','level':level})
                                    s.send({'id':'state','type':'get_state'})
                                s.state['thinking']=level; s.touch(True)
                        elif action=='command':
                            if s.state['provider']!='omp': raise ValueError('当前 Agent 不支持命令')
                            if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                            name=body.get('name','')
                            # The runtime has no generic command verb: probing
                            # execute_command/run_command/slash_command all returned
                            # "Unknown command". Only compact has its own RPC.
                            if name!='compact': raise ValueError('暂不支持在 Perch 中执行 /'+(name or '?')+'，请在终端使用')
                            if body.get('arguments'): raise ValueError('当前版本不支持 /compact 参数')
                            if not s.process or s.process.poll() is not None: raise ValueError('会话未在运行，请先发送一条消息')
                            if s.command_id: raise ValueError('上一条命令仍在执行')
                            s.command_id=str(uuid.uuid4()); s.state['commandResult']={'id':s.command_id,'status':'running'}
                            try: s.send({'id':s.command_id,'type':'compact'})
                            except Exception as e:
                                s.state['commandResult'].update(status='failed',error=str(e)); s.command_id=None
                                s.touch(True); raise
                            s.touch(True)
                        elif action=='abort':
                            if not body.get('turnId') or body['turnId']!=s.state.get('turnId'): raise ValueError('轮次已变化，请重新同步')
                            if s.state['busy'] and not s.state.get('stopRequested'):
                                if s.state['provider']=='dsh':
                                    if s.pending_prompt is not None:
                                        # The prompt never reached the runtime, so the
                                        # stop settles locally instead of on the wire.
                                        s.pending_prompt=None; s.state['cancelled']=True; s.state['busy']=False
                                        s.finish('stopped')
                                    elif s.state.get('resume'):
                                        s.acp_notify('session/cancel', {'sessionId':s.state['resume']})
                                    else: raise ValueError('会话尚未完成握手，请稍候')
                                else:
                                    s.send({'type':'abort','turnId':body['turnId']})
                                s.state['stopRequested']=True; s.touch(True)
                        elif action=='answer':
                            item=next(x for x in s.snapshot()['interactions'] if x['id']==body['id'])
                            if s.state['provider']=='omp':
                                answer={'type':'extension_ui_response','id':body['id']}
                                if body.get('cancelled'): answer['cancelled']=True
                                elif item['method']=='confirm': answer['confirmed']=body.get('allow',False)
                                else: answer['value']=body['value']
                                s.send(answer)
                            elif s.state['provider']=='dsh':
                                pending = s.permission_options.get(body['id'])
                                if not pending: raise ValueError('该审批已失效，请同步会话后重试')
                                if body.get('cancelled'):
                                    outcome = {'outcome':'cancelled'}
                                else:
                                    option_id = pending['map'].get(body.get('value'))
                                    if option_id is None: raise ValueError('未知的审批选项')
                                    outcome = {'outcome':'selected','optionId':option_id}
                                # Pop only after the answer is accepted on the wire; a
                                # rejected choice must not destroy the mapping.
                                s.send({'jsonrpc':'2.0','id':pending['wireId'],'result':{'outcome':outcome}})
                                s.permission_options.pop(body['id'], None)
                            else:
                                s.send({'type':'answer',**body})
                            s.state['interactions']=[x for x in s.state['interactions'] if x['id']!=body['id']]; s.touch(True)
                        elif action=='archive':
                            if s.state['busy']: raise ValueError('请先停止或完成任务')
                            s.state['archived']=body['archived']; s.touch(True)
                        elif action=='delete':
                            if s.state['busy']: raise ValueError('请先停止或完成任务')
                            s.deleted = True
                            if s.process and s.process.poll() is None: s.process.stdin.close()
                            # Deletion removes Workbench transcript only; upstream history remains available in the CLI.
                            s.path.unlink(); del SESSIONS[s.state['id']]
                        else: raise ValueError('未知操作')
                        if action not in ('prompt','steer'): result={'ok':True}
                else: raise ValueError('未知路径')
            self.respond(200,result)
        except Exception as e: self.respond(400,{'error':str(e)})
    def respond(self,status,body):
        data=json.dumps(body,ensure_ascii=False).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--ensure',action='store_true'); args=parser.parse_args()
    if args.ensure:
        import urllib.request
        endpoint=ROOT/'endpoint.json'
        if endpoint.exists():
            d=json.loads(endpoint.read_text())
            try:
                request=urllib.request.Request('http://127.0.0.1:'+str(d['port'])+'/health',headers={'Authorization':'Bearer '+d['token']})
                urllib.request.urlopen(request,timeout=2).read(); print(json.dumps(d)); sys.exit(0)
            except Exception: pass
        subprocess.Popen([sys.executable,__file__],stdin=subprocess.DEVNULL,stdout=open(ROOT/'service.log','a'),stderr=subprocess.STDOUT,start_new_session=True)
        for _ in range(100):
            time.sleep(.1)
            if endpoint.exists():
                d=json.loads(endpoint.read_text())
                try:
                    request=urllib.request.Request('http://127.0.0.1:'+str(d['port'])+'/health',headers={'Authorization':'Bearer '+d['token']})
                    urllib.request.urlopen(request,timeout=1).read(); print(json.dumps(d)); sys.exit(0)
                except Exception: pass
        raise SystemExit('托管服务未启动')
    lockfile=open(ROOT/'service.lock','w'); fcntl.flock(lockfile,fcntl.LOCK_EX|fcntl.LOCK_NB)
    TOKEN=secrets.token_urlsafe(32); load()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    save(ROOT/'endpoint.json',{'port':server.server_port,'token':TOKEN,'pid':os.getpid()})
    server.serve_forever()
