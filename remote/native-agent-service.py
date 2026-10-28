#!/usr/bin/env python3
"""SSH-only loopback broker. Owns Agent stdin independently of any Mac client."""
import argparse, bisect, base64, copy, datetime, fcntl, hashlib, hmac, json, os, pathlib, queue, secrets, shutil, signal, subprocess, sys, threading, time, traceback, urllib.request, uuid, warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote
ROOT = pathlib.Path(os.environ.get('AWB_NATIVE_ROOT', '~/.local/share/agent-workbench/native')).expanduser()
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
ROOT.chmod(0o700)
os.umask(0o077)
SERVICE_VERSION = 10
# Subagent text and thinking are forwarded into each subagent's own transcript.
# Probe 2026-10-18 (SDK 0.3.280, CLI 2.1.302): every subagent assistant/user
# message carried parent_tool_use_id, and no unparented stream delta held
# subagent-only text, so the main reply's streaming tail stays clean.
CLAUDE_FORWARD_SUBAGENT_TEXT = True
SUBAGENT_TOOLS = ('Agent', 'Task')
SUBAGENT_LIVE = ('queued', 'running')
SUBAGENT_TASK_EVENTS = ('task_started', 'task_progress', 'task_updated', 'task_notification')
SUBAGENT_PATCH_STATUS = {'pending':'queued', 'running':'running', 'paused':'running',
                         'completed':'completed', 'failed':'failed', 'killed':'stopped'}
SUBAGENT_KEYS = ('id', 'kind', 'taskId', 'toolUseIds', 'turnId', 'description', 'subagentType', 'status', 'background',
                 'startedAt', 'updatedAt', 'endedAt', 'usage', 'lastToolName', 'summary', 'error',
                 'canStop', 'stopRequested', 'stopError', 'messageCount', 'revision')
SUBAGENT_ROSTER_LIMIT = 64
SUBAGENT_SNAPSHOT_LIMIT = 32
SUBAGENT_MESSAGE_LIMIT = 2000
SUBAGENT_BYTE_LIMIT = 4 * 1024 * 1024
SUBAGENT_PART_LIMIT = 32 * 1024
SUBAGENT_WINDOW = 200
SUBAGENT_SAVE_DELAY = 2.0
# Live transcripts stay in memory; finished ones only while recently read.
SUBAGENT_RECENT_LIMIT = 8
# Codex child threads. Probe 2026-10-19 (codex-cli 0.162.1): a child's frames reach
# the parent's connection tagged with the child's threadId, the parent thread
# announces each child with subAgentActivity items, and no thread/started is sent.
CODEX_ACTIVITY_STATUS = {'interrupted':'stopped', 'completed':'completed'}
CODEX_AGENT_STATUS = {'pendingInit':'queued', 'running':'running', 'interrupted':'stopped', 'completed':'completed',
                      'errored':'failed', 'shutdown':'completed', 'notFound':'unknown'}
CODEX_TURN_STATUS = {'completed':'completed', 'interrupted':'stopped', 'failed':'failed'}
CODEX_CHILD_METHODS = ('item/started', 'item/completed', 'turn/started', 'turn/completed',
                       'thread/tokenUsage/updated', 'serverRequest/resolved')
# Frames of a thread that is not registered yet wait for it, this many and this long.
CODEX_PENDING_LIMIT = 256
CODEX_PENDING_SECONDS = 30.0
# A child's history is read at most this many pages of 100, and retried this late.
CODEX_BACKFILL_PAGES = 200
CODEX_BACKFILL_RETRY = 30.0

def source_fingerprint(path=None):
    """Identity of the code a service is executing. SERVICE_VERSION is bumped by
    hand, so a deployed change that keeps the number would otherwise leave the old
    process serving; the digest is reported next to the version and compared on
    every --ensure. An unreadable file reports nothing instead of a wrong digest."""
    try: return hashlib.sha256(pathlib.Path(path or __file__).read_bytes()).hexdigest()[:16]
    except OSError: return ''
SOURCE_FINGERPRINT = source_fingerprint()
STARTED_AT = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
LOCK = threading.RLock()
SESSIONS = {}
MODELS = None
CODEX_MODELS = None
QODER_MODELS = {}
MODEL_LOCK = threading.Lock()
DSH_MODELS = None
PERMISSION_MODES = {
    'omp': ('always-ask', 'write', 'yolo'),
    'qoder': ('default', 'acceptEdits', 'plan', 'dontAsk', 'auto', 'bypassPermissions'),
    'qoderintl': ('default', 'acceptEdits', 'plan', 'dontAsk', 'auto', 'bypassPermissions'),
    'dsh': ('runtime-managed',),
    'codex': ('read-only', 'workspace-ask', 'workspace-auto', 'full-access'),
    'claude': ('default', 'acceptEdits', 'plan', 'bypassPermissions'),
}
PERMISSION_DEFAULTS = {'omp':'always-ask', 'qoder':'default', 'qoderintl':'default', 'dsh':'runtime-managed', 'codex':'workspace-ask', 'claude':'default'}
PERMISSION_SCOPES = {'omp':'new-session', 'qoder':'next-turn', 'qoderintl':'next-turn', 'dsh':'runtime-managed', 'codex':'new-session', 'claude':'next-turn'}
QODER_SDK = {'qoder':'@qodercn-ai/qodercn-agent-sdk', 'qoderintl':'@qoder-ai/qoder-agent-sdk'}
QODER_CLI = {'qoder':'qoderclicn', 'qoderintl':'qodercli'}

def permission_mode(provider, value=None):
    mode = value if value is not None else PERMISSION_DEFAULTS[provider]
    if mode not in PERMISSION_MODES[provider]: raise ValueError('当前 Agent 不支持此权限模式')
    return mode

def restore_permission_mode(provider, value=None):
    if provider == 'codex':
        value = {'ask':'workspace-ask', 'auto-review':'workspace-ask'}.get(value, value)
    return value if value in PERMISSION_MODES[provider] else PERMISSION_DEFAULTS[provider]

def permission_capability(state):
    provider = state['provider']
    return {'selected':state['permissionMode'],
            'options':[] if provider == 'dsh' else list(PERMISSION_MODES[provider]),
            'scope':PERMISSION_SCOPES[provider]}

def model_catalog():
    global MODELS
    # CLI discovery must not hold the lock used by streaming, approvals and abort.
    with MODEL_LOCK:
        if MODELS is None:
            out=subprocess.run(['omp','models','--json','--no-extensions'],capture_output=True,text=True,timeout=60)
            if out.returncode!=0: raise ValueError('读取 omp 模型列表失败：'+(out.stderr or '').strip()[:200])
            payload=json.loads(out.stdout)
            items=payload['models'] if isinstance(payload,dict) else payload
            MODELS=[{k:m[k] for k in ('id','provider','name','contextWindow','thinking') if k in m} for m in items]
        return MODELS

def qoder_public_model(entry):
    fields = ('id', 'provider', 'name', 'contextWindow', 'thinking', 'defaultThinking', 'reasoning', 'isDefault')
    return {key:entry[key] for key in fields if key in entry}

def qoder_catalog(provider, live=False, timeout=60):
    global QODER_MODELS
    if provider not in QODER_SDK: raise ValueError('Unknown Qoder provider')
    with MODEL_LOCK:
        if not live and provider in QODER_MODELS: return QODER_MODELS[provider]
        node = shutil.which('node'); binary = shutil.which(QODER_CLI[provider])
        if not node: raise ValueError('未找到 node')
        if not binary: raise ValueError('未找到 ' + QODER_CLI[provider])
        if not (ROOT / 'node_modules' / QODER_SDK[provider] / 'package.json').is_file():
            raise ValueError('未安装 ' + QODER_SDK[provider])
        cfg = {'operation':'catalog', 'sdk':QODER_SDK[provider], 'binary':binary, 'cwd':str(ROOT)}
        out = subprocess.run([node, str(ROOT/'qoder-worker.mjs'), json.dumps(cfg)], cwd=str(ROOT),
                             env=proxy_aware_spawn_env(), capture_output=True, text=True, timeout=timeout)
        if out.returncode != 0:
            raise ValueError('读取 Qoder 模型列表失败：' + (out.stderr or out.stdout or 'unknown error').strip()[:200])
        lines = [line for line in out.stdout.splitlines() if line.strip()]
        if len(lines) != 1: raise ValueError('Qoder 模型列表返回格式无效')
        payload = json.loads(lines[0])
        items = payload.get('models') if isinstance(payload, dict) and payload.get('type') == 'models' else None
        if not isinstance(items, list): raise ValueError('Qoder 模型列表返回格式无效')
        models = []
        for item in items:
            if not isinstance(item, dict) or item.get('isEnabled') is False: continue
            model = item.get('value') or item.get('modelId')
            if not isinstance(model, str) or not model: continue
            efforts = []
            for effort in item.get('efforts') or []:
                if isinstance(effort, str) and effort and effort not in efforts: efforts.append(effort)
            vendor = item.get('provider') or item.get('outerProvider') or item.get('agent') or provider
            if not isinstance(vendor, str) or not vendor: vendor = provider
            entry = {'id':model, 'provider':vendor,
                     'name':item.get('displayName') if isinstance(item.get('displayName'), str) and item.get('displayName') else model,
                     'thinking':efforts, 'isDefault':item.get('isDefault') is True}
            context = item.get('maxInputTokens')
            if isinstance(context, int) and not isinstance(context, bool) and context > 0: entry['contextWindow'] = context
            if isinstance(item.get('isReasoning'), bool): entry['reasoning'] = item['isReasoning']
            default = item.get('defaultEffort')
            if isinstance(default, str) and default in efforts: entry['defaultThinking'] = default
            outer = item.get('outerProvider')
            if isinstance(outer, str) and outer: entry['_outerProvider'] = outer
            models.append(entry)
        QODER_MODELS[provider] = models
        return models

def qoder_selection(provider, model, thinking=None, catalog=None):
    if not model:
        if thinking: raise ValueError('使用 Qoder 默认模型时不能指定思考强度')
        return None, None
    source = qoder_catalog(provider) if catalog is None else catalog
    entry = next((item for item in source if item.get('id') == model), None)
    if entry is None: raise ValueError('Qoder 不认识该模型，请刷新模型列表后重试')
    if thinking and thinking not in entry.get('thinking', []): raise ValueError('当前 Qoder 模型不支持该思考强度')
    return entry, thinking or entry.get('defaultThinking')

def qoder_requested_model(state):
    return state.get('qoderRequestedModel', state.get('model', ''))

def apply_qoder_selection(state, entry, thinking):
    if entry is None:
        state['model'] = ''; state['qoderRequestedModel'] = ''; state['thinking'] = None
        for key in ('provider_id', 'qoderOuterProvider', 'qoderContextWindow'): state.pop(key, None)
        return
    state['model'] = entry['id']; state['qoderRequestedModel'] = entry['id']
    state['thinking'] = thinking; state['provider_id'] = entry['provider']
    if entry.get('_outerProvider'): state['qoderOuterProvider'] = entry['_outerProvider']
    else: state.pop('qoderOuterProvider', None)
    if entry.get('contextWindow'): state['qoderContextWindow'] = entry['contextWindow']
    else: state.pop('qoderContextWindow', None)

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

def codex_home(legacy=False):
    value = os.environ.get('CODEX_HOME') or str(pathlib.Path.home()/'.codex')
    marker = ROOT/'codex-home'
    if not legacy and marker.exists():
        value = marker.read_text().strip()
        if not value: raise ValueError('Codex HOME 配置为空')
    home = pathlib.Path(value).expanduser()
    if not home.is_absolute() or any(c in value for c in ('\n', '\r', '\0')):
        raise ValueError('Codex HOME 必须为绝对目录或以 ~/ 开头')
    return str(home.resolve())

def codex_credential_status(home):
    client = CodexAppServer(str(ROOT), home=home)
    try:
        client.initialize()
        account = client.request('account/read', {'refreshToken':False})
        if account.get('requiresOpenaiAuth') is False: return 'provider-managed'
        return 'present' if account.get('account') else 'missing'
    finally: client.close()

def setup_status(provider):
    """Readiness for the selected adapter only; never sends a model prompt.

    This runs outside LOCK, so CLI discovery cannot block active conversations.
    Return names/IDs and booleans only, never CLI configuration or credentials.
    """
    if provider not in ('omp', 'qoder', 'qoderintl', 'dsh', 'codex', 'claude'):
        raise ValueError('Unknown setup provider')
    try:
        if provider == 'dsh': binary = dsh_binary()
        elif provider == 'codex' and os.environ.get('PERCH_LOCAL_CODEX'): binary = os.environ['PERCH_LOCAL_CODEX']
        else: binary = shutil.which({'omp':'omp', 'qoder':'qoderclicn', 'qoderintl':'qodercli', 'codex':'codex', 'claude':'claude'}[provider])
    except ValueError:
        binary = None
    result = {'installed': bool(binary), 'models': [], 'modelCheck': 'unverified', 'credentialCheck': 'unverified'}
    if not binary: return result
    version = subprocess.run([binary, '--version'], capture_output=True, text=True, timeout=10)
    if version.returncode != 0:
        result.update(installed=False, error='The agent version command failed. Check it in an SSH terminal.')
        return result
    result['version'] = version.stdout.strip()[:120]
    if provider == 'omp':
        # Do not use the cached catalog: setup must see changes made by login/configuration.
        probe = subprocess.run([binary, 'models', '--json', '--no-extensions'], capture_output=True, text=True, timeout=20)
        if probe.returncode != 0:
            result['error'] = 'Could not read the OMP model catalog. Run omp models --json --no-extensions in an SSH terminal.'
            return result
        payload = json.loads(probe.stdout)
        catalog = payload['models'] if isinstance(payload, dict) else payload
        result['models'] = [{'id': m['id'], 'name': m.get('name', m['id']), 'provider': m.get('provider', '')}
                            for m in catalog if isinstance(m, dict) and m.get('id')]
        result['modelCheck'] = 'configured' if result['models'] else 'missing'
    elif provider in ('qoder', 'qoderintl'):
        result['sdkInstalled'] = (ROOT / 'node_modules' / QODER_SDK[provider] / 'package.json').is_file()
        result['nodeInstalled'] = bool(shutil.which('node'))
        if not result['sdkInstalled'] or not result['nodeInstalled']:
            result['modelCheck'] = 'missing'
            return result
        try:
            catalog = qoder_catalog(provider, live=True)
        except Exception:
            result['credentialCheck'] = 'missing'
            result['modelCheck'] = 'missing'
            result['error'] = 'Could not read the Qoder model catalog. Run ' + QODER_CLI[provider] + ' login in an SSH terminal.'
            return result
        result['credentialCheck'] = 'present'
        result['models'] = [qoder_public_model(model) for model in catalog]
        result['modelCheck'] = 'configured' if result['models'] else 'missing'
    elif provider == 'claude':
        result['sdkInstalled'] = (ROOT / 'node_modules/@anthropic-ai/claude-agent-sdk/package.json').is_file()
        result['nodeInstalled'] = bool(shutil.which('node'))
        # The SDK resolves the model and login at the first query; no model-list API.
        result['modelCheck'] = 'runtime-default'
    elif provider == 'dsh':
        result['credentialCheck'] = 'present' if os.environ.get('DEEPSEEK_API_KEY') else 'missing'
        result['models'] = [{'id': m['id'], 'name': m.get('name', m['id']), 'provider': m.get('provider', '')}
                            for m in dsh_catalog() if m.get('id')]
        result['modelCheck'] = 'session-handshake'
    else:
        try:
            home = codex_home()
            result['credentialCheck'] = codex_credential_status(home)
            if result['credentialCheck'] == 'missing': return result
            catalog = codex_catalog(home)
        except Exception:
            result['error'] = 'Could not check the configured Codex runtime. Check its HOME and app-server configuration.'
            return result
        result['models'] = [{'id': m['id'], 'name': m.get('name', m['id']), 'provider': 'codex'}
                            for m in catalog if isinstance(m, dict) and m.get('id')]
        result['modelCheck'] = 'configured' if result['models'] else 'missing'
    return result

def save(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False)); tmp.replace(path)

def proxy_aware_spawn_env():
    env = dict(os.environ)
    if any(env.get(key) for key in ('http_proxy', 'https_proxy', 'all_proxy',
                                    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')): return env
    try:
        urllib.request.urlopen('http://127.0.0.1:9090/version', timeout=1).close()
        values = {}
        for line in (pathlib.Path.home()/'proxy.env').read_text().splitlines():
            line = line.strip()
            if line.startswith('export '): line = line[7:].lstrip()
            if not line or line.startswith('#') or '=' not in line: continue
            key, _, val = line.partition('=')
            val = val.strip().strip('"\'')
            if val.startswith('$'): val = values.get(val[1:], '')
            if val: values[key.strip()] = val
        env.update(values)
    except Exception: pass
    return env

class CodexAppServer:
    def __init__(self, cwd, on_frame=None, on_exit=None, stderr_path=None, home=None):
        binary = os.environ.get('PERCH_LOCAL_CODEX') or shutil.which('codex')
        if not binary: raise ValueError('未找到 codex CLI，请先安装并登录 Codex')
        self.home = home or codex_home()
        self.on_frame = on_frame; self.on_exit = on_exit; self.closing = False
        self.write_lock = threading.Lock(); self.pending_lock = threading.Lock()
        self.pending = {}; self.next_id = 0; self.frames = queue.Queue()
        self.stderr = open(stderr_path, 'a') if stderr_path else subprocess.DEVNULL
        env = proxy_aware_spawn_env()
        env['CODEX_HOME'] = self.home
        if os.environ.get('PERCH_LOCAL_CODEX'):
            # App-bundled CLIs are often symlinked into ~/.local/bin. Their tool
            # helpers live beside the actual executable, not beside the link.
            binary = str(pathlib.Path(binary).resolve())
            env['PATH'] = str(pathlib.Path(binary).parent) + os.pathsep + env.get('PATH', '')
        self.process = subprocess.Popen([binary,'app-server','--listen','stdio://'],cwd=cwd,
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.stderr,text=True,bufsize=1,start_new_session=True,env=env)
        threading.Thread(target=self.dispatch,daemon=True).start()
        threading.Thread(target=self.read,daemon=True).start()

    def initialize(self):
        self.request('initialize', {'clientInfo':{'name':'perch','title':'Perch','version':'1'},
                                    'capabilities':{'experimentalApi':True}}, timeout=20)
        self.notify('initialized', {})

    def send(self, value):
        if self.process.poll() is not None: raise ValueError('Codex app-server 已退出')
        with self.write_lock:
            self.process.stdin.write(json.dumps(value,ensure_ascii=False)+'\n'); self.process.stdin.flush()

    def request(self, method, params, timeout=60):
        with self.pending_lock:
            self.next_id += 1; request_id = 'perch-' + str(self.next_id)
            slot = {'event':threading.Event()}; self.pending[request_id] = slot
        try: self.send({'jsonrpc':'2.0','id':request_id,'method':method,'params':params})
        except Exception:
            with self.pending_lock: self.pending.pop(request_id,None)
            raise
        if not slot['event'].wait(timeout):
            with self.pending_lock: self.pending.pop(request_id,None)
            raise ValueError('Codex app-server 请求超时：'+method)
        frame = slot['frame']
        if frame.get('error'):
            error = frame['error']; message = error.get('message') if isinstance(error,dict) else str(error)
            raise ValueError('Codex 拒绝 '+method+'：'+(message or '未知错误'))
        return frame.get('result') or {}

    def notify(self, method, params):
        self.send({'jsonrpc':'2.0','method':method,'params':params})

    def respond(self, request_id, result=None, error=None):
        frame = {'jsonrpc':'2.0','id':request_id}
        if error is not None: frame['error'] = error
        else: frame['result'] = result or {}
        self.send(frame)

    def read(self):
        failure = None
        try:
            for line in self.process.stdout:
                frame = json.loads(line)
                if 'method' in frame:
                    self.frames.put(frame); continue
                request_id = frame.get('id')
                with self.pending_lock: slot = self.pending.pop(request_id,None)
                if slot is not None:
                    slot['frame'] = frame; slot['event'].set()
        except Exception as e: failure = str(e)
        finally:
            if failure is None and not self.closing: failure = 'Codex app-server 已退出'
            with self.pending_lock:
                pending = list(self.pending.values()); self.pending.clear()
            for slot in pending:
                slot['frame'] = {'error':{'message':failure or 'Codex app-server 已关闭'}}; slot['event'].set()
            self.frames.put(None)
            if self.on_exit: self.on_exit(self, failure)

    def dispatch(self):
        while True:
            frame = self.frames.get()
            if frame is None: return
            try:
                if self.on_frame: self.on_frame(frame)
                elif 'id' in frame: self.respond(frame['id'], error={'code':-32601,'message':'unsupported by catalog client'})
            except Exception:
                if 'id' in frame:
                    try: self.respond(frame['id'], error={'code':-32603,'message':'Perch failed to handle request'})
                    except Exception: pass

    def close(self):
        self.closing = True
        try: self.process.stdin.close()
        except Exception: pass
        if self.process.poll() is None: self.process.terminate()
        if self.stderr is not subprocess.DEVNULL:
            try: self.stderr.close()
            except Exception: pass

def codex_catalog(home=None):
    global CODEX_MODELS
    home = home or codex_home()
    with MODEL_LOCK:
        if CODEX_MODELS is None: CODEX_MODELS = {}
        if home in CODEX_MODELS: return CODEX_MODELS[home]
        client = CodexAppServer(str(ROOT), home=home)
        try:
            client.initialize(); items = []; cursor = None
            while True:
                params = {'includeHidden':False}
                if cursor: params['cursor'] = cursor
                page = client.request('model/list', params)
                items.extend(page.get('data') or []); cursor = page.get('nextCursor')
                if not cursor: break
            CODEX_MODELS[home] = [
                {'id':m.get('model') or m['id'],'provider':'codex','name':m.get('displayName') or m.get('model') or m['id'],
                 'thinking':[x.get('reasoningEffort') for x in m.get('supportedReasoningEfforts',[]) if x.get('reasoningEffort')],
                 'defaultThinking':m.get('defaultReasoningEffort')}
                for m in items if m.get('id') and not m.get('hidden',False)
            ]
            return CODEX_MODELS[home]
        finally: client.close()

def codex_selection(model, thinking=None, catalog=None):
    if not model: raise ValueError('请选择 Codex 模型')
    source = codex_catalog() if catalog is None else catalog
    entry = next((item for item in source if item.get('id') == model), None)
    if entry is None: raise ValueError('Codex 不认识该模型，请刷新模型列表后重试')
    if thinking and thinking not in entry.get('thinking',[]): raise ValueError('当前 Codex 模型不支持该思考强度')
    return entry, thinking or entry.get('defaultThinking')

def catalog_entries(value, agent):
    # OMP emits {"models": [...]}; the other adapters provide normalized lists.
    if isinstance(value, dict):
        value = next((value[name] for name in ('models', 'items') if isinstance(value.get(name), list)), [])
    if not isinstance(value, list): return []
    if agent in QODER_SDK: value = [qoder_public_model(entry) for entry in value if isinstance(entry, dict)]
    return [dict(entry, agent=agent) for entry in value if isinstance(entry, dict)]

def combined_catalog():
    entries = catalog_entries(dsh_catalog(), 'dsh'); errors = []
    sources = (('omp', model_catalog), ('qoder', lambda:qoder_catalog('qoder', timeout=10)),
               ('qoderintl', lambda:qoder_catalog('qoderintl', timeout=10)), ('codex', codex_catalog))
    for agent, discover in sources:
        try:
            values = discover()
            entries.extend(catalog_entries(values, agent))
        except Exception as e: errors.append(e)
    if entries: return entries
    if errors: raise errors[0]
    return []

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
        if kind in ('text','thinking'):
            part={'type':kind, kind:p.get(kind,'')}
            if isinstance(p.get('source'),dict): part['source']=p['source']
            parts.append(part)
        elif kind in ('toolCall','tool_use'): parts.append({'type':'tool_use','tool_call_id':p.get('id'),'tool_name':p.get('name'),'input':p.get('arguments',p.get('input',{}))})
        elif kind == 'tool_result': parts.append({'type':kind,'tool_call_id':p.get('tool_use_id'),'output':p.get('content'),'is_error':p.get('is_error',False)})
        elif kind == 'image': parts.append({'type':'text','text':'[图片]'})
    return {'id':identity,'role':role,'content':parts,'created_at':str(message.get('timestamp',''))}

def is_user_prompt(message):
    # Match KimiMessage.isUserPrompt: injected context must not split a page
    # away from the actual user prompt and its tool/reply messages.
    def context(part):
        if part.get('type') != 'text': return False
        value = part.get('text', '').strip()
        if part.get('source', {}).get('kind') == 'runtime_context': return True
        # Older Claude snapshots lost the SDK's synthetic-message marker.
        if value.startswith('Base directory for this skill: ') and '\n' in value: return True
        if value.startswith('<system-reminder>'): return True
        if any(value.startswith(a) and value.endswith(b) for a,b in (
            ('<notification ', '</notification>'), ('<skill-loaded ', '</skill-loaded>'), ('<system>', '</system>'))): return True
        if value.endswith('</skill-loaded>') and '\n' in value:
            block = value.split('\n', 1)[1].lstrip()
            return block.startswith('<skill-loaded ') and 'trigger="model-tool"' in block.split('>', 1)[0]
        return False
    return message['role'] == 'user' and message.get('metadata', {}).get('origin', {}).get('kind') != 'compaction_summary' and not all(p.get('type') == 'tool_result' or context(p) for p in message['content'])

def iso_time(value=None):
    """UTC with milliseconds and Z: what the client's KimiTask date parser reads."""
    value = time.time() if value is None else value
    return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

def iso_seconds(value):
    try: return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except Exception: return time.time()

def epoch_seconds(value):
    """Codex reports times in seconds or milliseconds; None for anything else."""
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0: return None
    return value / 1000 if value > 100000000000 else value

def clip_chars(value, limit):
    if not isinstance(value, str) or not value.strip(): return None
    value = value.strip()
    return value if len(value) <= limit else value[:limit-1] + '…'

def json_size(value):
    # Runtime text may hold lone surrogates; a size estimate must not fail on them.
    return len(json.dumps(value, ensure_ascii=False).encode('utf-8', 'surrogatepass'))

def clip_bytes(text, limit=SUBAGENT_PART_LIMIT):
    if len(text) <= limit // 4: return text
    data = text.encode('utf-8', 'surrogatepass')
    if len(data) <= limit: return text
    marker = '\n…[已截断，原文 %d 字节]' % len(data)
    return data[:max(0, limit - len(marker.encode()))].decode('utf-8', 'ignore') + marker

def clip_output(value):
    """Tool output of a subagent transcript, at most one part limit in total."""
    if isinstance(value, str): return clip_bytes(value)
    size = json_size(value)
    if size <= SUBAGENT_PART_LIMIT: return value
    if not isinstance(value, list): return '…[已截断，原文 %d 字节]' % size
    result = []; budget = SUBAGENT_PART_LIMIT
    for item in value:
        text = item.get('text') if isinstance(item, dict) and item.get('type') == 'text' else None
        if budget <= 256:
            result.append({'type':'text', 'text':'…[已截断，原文 %d 字节]' % size}); break
        if isinstance(text, str):
            text = clip_bytes(text, budget); result.append(dict(item, text=text))
        elif json_size(item) <= budget: result.append(item)
        else: result.append({'type':'text', 'text':'[已省略 %d 字节的内容]' % json_size(item)})
        budget -= json_size(result[-1])
    return result

def clip_value(value):
    """Every string anywhere inside a tool input, each at most one part limit."""
    if isinstance(value, str): return clip_bytes(value)
    if isinstance(value, list): return [clip_value(item) for item in value]
    if isinstance(value, dict): return {key:clip_value(item) for key, item in value.items()}
    return value

def clip_subagent_message(message):
    for part in message['content']:
        kind = part.get('type')
        if kind in ('text', 'thinking') and isinstance(part.get(kind), str): part[kind] = clip_bytes(part[kind])
        elif kind == 'tool_result': part['output'] = clip_output(part.get('output'))
        elif kind == 'tool_use': part['input'] = clip_value(part.get('input'))
    # Many capped parts can still make one huge message. Past the trim target it
    # would keep its transcript over budget however much else is trimmed, so it
    # becomes a notice; the trim then always reaches its target.
    size = json_size(message)
    if size > SUBAGENT_BYTE_LIMIT * 3 // 4:
        message['content'] = [{'type':'text', 'text':'…[消息过大，已省略，原文 %d 字节]' % size}]
    return message

def tool_result_text(content):
    if isinstance(content, str): return content
    if not isinstance(content, list): return ''
    return '\n'.join(p['text'] for p in content if isinstance(p, dict) and p.get('type') == 'text' and isinstance(p.get('text'), str))

def subagent_call(value):
    """What the main thread's Agent/Task tool_use says about the child it spawns."""
    value = value if isinstance(value, dict) else {}
    prompt = value.get('prompt') if isinstance(value.get('prompt'), str) else ''
    description = clip_chars(value.get('description'), 200) or clip_chars(next((line for line in prompt.splitlines() if line.strip()), ''), 200)
    kind = value.get('subagent_type')
    background = value.get('run_in_background')
    return {'description':description, 'subagentType':kind if isinstance(kind, str) and kind else None,
            'background':background if isinstance(background, bool) else None}

def subagent_usage(value):
    if not isinstance(value, dict): return None
    def number(key):
        item = value.get(key)
        return int(item) if isinstance(item, (int, float)) and not isinstance(item, bool) else 0
    return {'totalTokens':number('total_tokens'), 'toolUses':number('tool_uses'), 'durationMs':number('duration_ms')}

def subagent_filename(key):
    # Keys come from the runtime; anything outside a plain id becomes a digest so it
    # can never leave the session's folder. Digests start with "_", plain ids cannot.
    if 0 < len(key) <= 120 and key[0].isascii() and key[0].isalnum() and all(c.isascii() and (c.isalnum() or c in '_-') for c in key):
        return key + '.json'
    return '_' + hashlib.sha256(key.encode('utf-8', 'surrogatepass')).hexdigest()[:32] + '.json'

def subagent_transcript_state(messages=(), truncated=0, versions=None):
    # Positions of a transcript belong to one epoch, exactly as main history does.
    messages = list(messages); sizes = [json_size(m) for m in messages]
    return {'epoch':uuid.uuid4().hex, 'truncated':truncated, 'messages':messages, 'versions':dict(versions or {}),
            'index':{m['id']:i for i, m in enumerate(messages)}, 'sizes':sizes, 'bytes':sum(sizes),
            'tools':{p.get('tool_call_id') for m in messages for p in m['content'] if p.get('type') == 'tool_use'}}

def subagent_label(agent_id, entry):
    return {'id':entry['id'] if entry else None, 'agentId':agent_id,
            'title':entry['description'] if entry else None, 'type':entry['subagentType'] if entry else None}

def codex_agent_name(path):
    """The last segment of a Codex child's agentPath: "/root/list_files" is "list_files"."""
    return clip_chars(path.rstrip('/').rsplit('/', 1)[-1], 200) if isinstance(path, str) else None

def codex_text_value(value):
    return value if isinstance(value, str) and value else None

def codex_permission_params(mode, turn=False):
    mode = permission_mode('codex', mode)
    policy, sandbox, turn_sandbox = {
        'read-only': ('on-request', 'read-only', 'readOnly'),
        'workspace-ask': ('on-request', 'workspace-write', 'workspaceWrite'),
        'workspace-auto': ('never', 'workspace-write', 'workspaceWrite'),
        'full-access': ('never', 'danger-full-access', 'dangerFullAccess'),
    }[mode]
    params = {'approvalPolicy':policy, 'approvalsReviewer':'user'}
    if turn: params['sandboxPolicy'] = {'type':turn_sandbox}
    else: params['sandbox'] = sandbox
    return params

class Session:
    def __init__(self, state):
        provider = state.get('provider')
        if provider in PERMISSION_MODES:
            state['permissionMode'] = restore_permission_mode(provider, state.get('permissionMode'))
        if provider == 'codex':
            state['context'] = None
            if not state.get('codexHome'): state['codexHome'] = codex_home(legacy=True)
        self.state = state; self.process = None; self.write_lock = threading.Lock(); self.last_save = 0; self.deleted = False
        self.path = ROOT / 'sessions' / (state['id'] + '.json')
        self.ready = threading.Event(); self.chunks = None; self.command_id = None
        self.sdk_block_index = None
        self.acp_pending = {}; self.acp_next_id = 0; self.pending_prompt = None
        self.acp_blocks = {}; self.permission_options = {}
        self.codex = None; self.codex_attached = False; self.codex_parts = {}; self.codex_outputs = {}
        self.codex_interactions = {}
        # Codex children: item parts by child, frames waiting for their thread to
        # register (arrival time, thread id, frame), and history reads by entry key.
        self.codex_child_parts = {}; self.codex_pending = []; self.codex_backfills = {}
        # Transcripts load on first use; the roster in state is their only index.
        self.subagent_transcripts = {}; self.subagent_dirty = set(); self.subagent_timer = None
        self.subagent_calls = {}; self.subagent_ignored = set()
        # Finished transcripts in memory, least recently used first, and the epoch
        # each evicted one was flushed under.
        self.subagent_recent = {}; self.subagent_written = {}
        self.index_subagents()
        self.reset_history_index()
        # Version 1 stored command results as plain strings in existing histories.
        previous=state.get('commandResult')
        if isinstance(previous,str):
            state['commandResult']={'id':'restored-command','status':'completed' if previous=='已完成' else 'unknown',
                                    'error':None if previous=='已完成' else '此前命令结果：'+previous}
    def reset_history_index(self):
        # Epoch changes when history is replaced or the bridge restarts. Never
        # apply positions from a different history, even if revisions coincide.
        self.history_epoch = uuid.uuid4().hex
        self.message_indices = {m['id']: i for i, m in enumerate(self.state['messages'])}
        self.message_versions = {}
        self.prompt_indices = [i for i, m in enumerate(self.state['messages']) if is_user_prompt(m)]
    def persist(self):
        self.path.parent.mkdir(exist_ok=True); save(self.path, self.state); self.last_save = time.monotonic()
    def touch(self, durable=False):
        self.state['revision'] += 1
        if durable or time.monotonic()-self.last_save > 1: self.persist()
    def summary(self):
        return {k:self.state[k] for k in ('id','provider','title','cwd','busy','archived','updated','revision','completed','model','error')} | {
            'pending':len(self.state['interactions']), 'cancelled':self.state.get('cancelled',False),
            'thinking':self.state.get('thinking'), 'context':self.state.get('context'),
            'permission':permission_capability(self.state),
            'turnId':self.state.get('turnId'), 'turnState':self.state.get('turnState'),
            'steer':self.state['provider'] in ('omp','codex'),
            'runningSubagents':sum(1 for x in self.state.get('subagentRoster') or [] if x.get('status') in SUBAGENT_LIVE),
            'qoderRequestedModel':qoder_requested_model(self.state) if self.state['provider'] in QODER_SDK else None}
    def active_receipt(self):
        turn = self.state.get('turnId')
        direct = self.state.get('requests',{}).get(turn)
        if direct: return direct
        return next((r for r in self.state.get('requests',{}).values() if r.get('runtimeTurnId')==turn),None)
    def finish(self, status):
        self.state['turnState']=status
        receipt=self.active_receipt()
        if receipt:
            receipt['status']=status
            receipt['error']=self.state.get('error')
    def decode_attachments(self, value):
        if not value: return []
        if self.state['provider'] not in ('claude','codex'): raise ValueError('当前 Agent 不支持发送附件')
        if not isinstance(value, list) or len(value) > 5: raise ValueError('附件一次最多 5 个')
        result = []
        for item in value:
            if not isinstance(item, dict): raise ValueError('附件格式无效')
            name = os.path.basename(str(item.get('name') or 'attachment')).replace('\x00', '') or 'attachment'
            media = str(item.get('mediaType') or 'application/octet-stream')
            try: data = base64.b64decode(str(item.get('data') or ''), validate=True)
            except Exception: raise ValueError('附件内容编码无效')
            if not data or len(data) > 10485760: raise ValueError('附件为空或超过 10MB：' + name)
            result.append({'name': name, 'mediaType': media, 'data': data})
        return result
    def store_attachments(self, request_id, attachments):
        folder = ROOT / 'attachments' / self.state['id'] / request_id
        folder.mkdir(parents=True, exist_ok=True); folder.chmod(0o700)
        stored = []
        for i, item in enumerate(attachments):
            path = folder / ('%02d-' % i + item['name'])
            path.write_bytes(item['data']); path.chmod(0o600)
            stored.append({'name': item['name'], 'mediaType': item['mediaType'], 'path': str(path)})
        return stored
    def prompt(self, body):
        s=self.state; request_id=body.get('requestId')
        if not isinstance(request_id,str) or not request_id: raise ValueError('缺少 requestId，请更新客户端')
        text=body['text']; attachments=self.decode_attachments(body.get('attachments'))
        digest=hashlib.sha256(text.encode()).hexdigest()
        for item in attachments:
            digest+=':'+hashlib.sha256(item['name'].encode()+item['mediaType'].encode()+item['data']).hexdigest()
        receipts=s.setdefault('requests',{})
        if request_id in receipts:
            receipt=receipts[request_id]
            if receipt['digest']!=digest: raise ValueError('requestId 已用于另一条消息')
            return copy.deepcopy(receipt)
        if s['busy'] or s['archived']: raise ValueError('会话正在运行或已归档')
        if not text.strip() and not attachments: raise ValueError('消息不能为空')
        if s['provider']=='codex': self.codex_ensure(True)
        elif not self.process or self.process.poll() is not None: self.launch()
        stored=self.store_attachments(request_id,attachments) if attachments else []
        receipt={'id':request_id,'digest':digest,'text':text,'status':'submitting'}
        receipts[request_id]=receipt
        s.update(busy=True,error=None,cancelled=False,stopRequested=False,stopAcknowledged=False,
                 updated=time.time(),turnId=request_id,turnState='submitting')
        content=text
        if stored:
            marks=['[图片: %s]'%a['name'] if a['mediaType'].startswith('image/') else '[附件: %s]'%a['name'] for a in stored]
            content=(text+'\n' if text.strip() else '')+'\n'.join(marks)
        if not s['messages']: s['title']=content[:60]
        if s['provider'] in ('qoder','qoderintl','dsh','codex','claude'): self.upsert({'role':'user','content':content},request_id)
        if s['provider']=='dsh':
            self.pending_prompt=(request_id,text)
            try:
                if self.ready.is_set(): self.acp_flush_prompt()
            except Exception as e:
                s['busy']=False; s['error']=str(e); self.finish('unknown')
            self.touch(True)
            return copy.deepcopy(receipt)
        self.touch(True)
        try:
            if s['provider']=='codex':
                # Images ride the turn as localImage items referencing the stored
                # files; other attachments are noted in the text with their path.
                prompt_text=text; images=[]
                for a in stored:
                    if a['mediaType'].startswith('image/'):
                        images.append({'type':'localImage','path':a['path']})
                    else:
                        prompt_text+='\n[Attached file %s is saved at %s; inspect it with the Read tool.]'%(a['name'],a['path'])
                input_items=[{'type':'text','text':prompt_text}] if prompt_text.strip() else []
                params={'threadId':s['resume'],'input':input_items+images,
                        'clientUserMessageId':request_id} | codex_permission_params(s['permissionMode'], turn=True)
                if s.get('model'): params['model']=s['model']
                if s.get('thinking'): params['effort']=s['thinking']
                turn=(self.codex.request('turn/start',params).get('turn') or {})
                if not turn.get('id'): raise ValueError('Codex turn/start 未返回 turn id')
                s['turnId']=turn['id']; receipt['runtimeTurnId']=turn['id']
                receipt['status']='accepted'; s['turnState']='running' if turn.get('status')=='inProgress' else 'accepted'
            else:
                message={'type':'prompt','id':request_id,'message':text}
                if s['provider'] in ('qoder','qoderintl','claude'): message['permissionMode']=s['permissionMode']
                if s['provider'] in QODER_SDK:
                    requested_model = qoder_requested_model(s)
                    message['model']=requested_model
                    if requested_model:
                        if s.get('thinking'): message['thinking']=s['thinking']
                        if s.get('qoderOuterProvider'): message['outerProvider']=s['qoderOuterProvider']
                        if s.get('qoderContextWindow'): message['contextWindow']=s['qoderContextWindow']
                if stored: message['attachments']=stored
                self.send(message)
                receipt['status']='submitted'; s['turnState']='submitted'
        except Exception as e:
            s['busy']=False; s['error']=str(e); self.finish('unknown')
        self.touch(True)
        return copy.deepcopy(receipt)
    def launch(self):
        s = self.state
        if s['provider']=='codex': self.codex_ensure(True); return
        env = None
        if s['provider'] == 'omp':
            args = ['omp','--mode','rpc-ui','--cwd',s['cwd'],'--approval-mode',s['permissionMode'],'--no-title','--session-dir',str(ROOT/'omp-sessions')]
            if s.get('resume'): args += ['--resume',s['resume']]
            if s['model']: args += ['--model',s['model']]
            if s.get('thinking'): args += ['--thinking',s['thinking']]
        elif s['provider'] == 'dsh':
            args = [dsh_binary(),'--profile','acp']
            env = dict(os.environ, DSH_HOME=str(ROOT/'dsh-home'), DSH_TELEMETRY_MODE='DISABLED')
        else:
            cli = QODER_CLI.get(s['provider'], 'claude')
            worker = 'qoder-worker.mjs' if s['provider'] in QODER_SDK else 'claude-worker.mjs'
            model = qoder_requested_model(s) if s['provider'] in QODER_SDK else s['model']
            cfg = {'cwd':s['cwd'],'model':model,'resume':s.get('resume'),'binary':shutil.which(cli)}
            if s['provider'] in QODER_SDK: cfg['sdk'] = QODER_SDK[s['provider']]
            else: cfg['forwardSubagentText'] = CLAUDE_FORWARD_SUBAGENT_TEXT
            if not cfg['binary']: raise ValueError('未找到 ' + cli)
            args = ['node',str(ROOT/worker),json.dumps(cfg)]
            # The Claude CLI also phones home (feature flags, telemetry) outside the
            # model gateway; without the proxy env those calls stall the turn silently.
            if s['provider'] == 'claude': env = proxy_aware_spawn_env()
        self.ready.clear()
        self.acp_pending = {}; self.acp_next_id = 0; self.pending_prompt = None
        self.acp_blocks = {}; self.permission_options = {}
        self.process = subprocess.Popen(args,cwd=s['cwd'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(ROOT/(s['id']+'.stderr'),'a'),text=True,start_new_session=True,env=env)
        threading.Thread(target=self.read,daemon=True).start()
        if s['provider'] == 'dsh':
            self.acp_request('initialize', {'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False}}}, 'initialize')
    def send(self, value):
        if not self.process or self.process.poll() is not None: raise ValueError('远端进程已退出，请重新发送以恢复会话')
        with self.write_lock:
            self.process.stdin.write(json.dumps(value,ensure_ascii=False)+'\n'); self.process.stdin.flush()
    def codex_open_params(self):
        params={'cwd':self.state['cwd']} | codex_permission_params(self.state['permissionMode'])
        if self.state.get('model'): params['model']=self.state['model']
        provider = self.state.get('provider_id')
        if provider and provider != 'codex': params['modelProvider'] = provider
        return params
    def codex_ensure(self, attach=True):
        if self.codex and self.codex.process.poll() is None:
            if not attach or self.codex_attached: return self.codex
        else:
            client=CodexAppServer(self.state['cwd'],stderr_path=ROOT/(self.state['id']+'.stderr'),home=self.state['codexHome'])
            client.on_frame=lambda frame: self.codex_frame(client,frame)
            client.on_exit=self.codex_exit
            self.codex=client; self.codex_attached=False
            self.codex_pending=[]; self.codex_child_parts={}
            try: client.initialize()
            except Exception:
                client.close(); self.codex=None
                raise
        if attach and not self.codex_attached:
            if not self.state.get('resume'):
                self.codex_start_thread()
            else:
                params=self.codex_open_params() | {'threadId':self.state['resume'],'excludeTurns':True}
                result=self.codex.request('thread/resume',params)
                self.codex_apply_thread(result)
                self.codex_attached=True
                self.codex_hydrate()
                self.touch(True)
        return self.codex
    def codex_start_thread(self):
        self.codex_ensure(False)
        result=self.codex.request('thread/start',self.codex_open_params())
        thread=result.get('thread') or {}
        native_id=thread.get('id')
        if not native_id: raise ValueError('Codex thread/start 未返回 thread id')
        old_id=self.state['id']; old_path=self.path
        if native_id in SESSIONS and SESSIONS[native_id] is not self: raise ValueError('Codex 返回了已存在的 thread id')
        self.state['id']=native_id; self.state['resume']=native_id
        self.path=ROOT/'sessions'/(native_id+'.json')
        if SESSIONS.get(old_id) is self:
            del SESSIONS[old_id]; SESSIONS[native_id]=self
        self.codex_apply_thread(result); self.codex_attached=True; self.persist()
        if old_path != self.path and old_path.exists(): old_path.unlink()
        return native_id
    def codex_apply_thread(self, result):
        s=self.state; thread=result.get('thread') or {}
        if thread.get('id') and s.get('resume') and thread['id']!=s['resume']:
            raise ValueError('Codex 返回了不匹配的 thread id')
        s['model']=result.get('model') or thread.get('model') or s.get('model','')
        s['provider_id']=result.get('modelProvider') or thread.get('modelProvider') or s.get('provider_id')
        if not s.get('thinking'):
            if 'reasoningEffort' in result: s['thinking']=result.get('reasoningEffort')
            elif 'reasoningEffort' in thread: s['thinking']=thread.get('reasoningEffort')
        if thread.get('updatedAt'): s['updated']=thread['updatedAt']
    def codex_hydrate(self):
        self.state['messages']=[]; self.reset_history_index(); self.codex_parts={}; self.codex_outputs={}
        cursor=None
        while True:
            params={'threadId':self.state['resume'],'sortDirection':'asc','limit':100}
            if cursor: params['cursor']=cursor
            page=self.codex.request('thread/items/list',params)
            for entry in page.get('data') or []:
                # History registers the children its subAgentActivity items name.
                self.codex_item(entry.get('item') or {},True,turn_id=entry.get('turnId'),history=True,
                                at=entry.get('startedAtMs') or entry.get('completedAtMs'))
            cursor=page.get('nextCursor')
            if not cursor: break
    def codex_text(self, value):
        if value is None: return ''
        if isinstance(value,str): return value
        if isinstance(value,list):
            texts=[]
            for item in value:
                if isinstance(item,str): texts.append(item)
                elif isinstance(item,dict):
                    text=item.get('text') or item.get('output_text')
                    texts.append(text if isinstance(text,str) else json.dumps(item,ensure_ascii=False))
                else: texts.append(str(item))
            return '\n'.join(texts)
        return json.dumps(value,ensure_ascii=False,indent=2)
    def codex_reasoning_text(self, item_id, target=None):
        parts=self.codex_target_parts(target).get(item_id) or {}
        values=[]
        for kind in ('summary','content'):
            values.extend(text for _,text in sorted((parts.get(kind) or {}).items()) if text)
        return '\n'.join(values)
    def codex_reasoning_source(self, item_id, completed=False, target=None):
        parts=self.codex_target_parts(target).get(item_id) or {}
        source={'kind':'activity_summary','provider':'codex','itemId':str(item_id),
                'summaryParts':[text for _,text in sorted((parts.get('summary') or {}).items()) if text],
                'state':'final' if completed else 'streaming'}
        turn=self.state.get('turnId') if target is None else target.get('turnId')
        if turn: source['turnId']=turn
        return source
    def codex_upsert_reasoning(self, item_id, completed=False, timestamp=None, native_summary=True, target=None):
        part={'type':'thinking','thinking':self.codex_reasoning_text(item_id,target)}
        if native_summary: part['source']=self.codex_reasoning_source(item_id,completed,target)
        self.codex_write(target,{'role':'assistant','content':[part],'timestamp':timestamp or time.time()},'codex:'+str(item_id))
    def codex_target_parts(self, target=None):
        # Streaming state of the main thread, or of one child's transcript.
        return self.codex_parts if target is None else self.codex_child_parts.setdefault(target['id'],{})
    def codex_write(self, target, message, identity):
        if target is None: self.upsert(message,identity)
        else: self.subagent_append(target,clip_subagent_message(copy.deepcopy(normalize(message,identity))))
    def codex_item(self, item, completed=False, timestamp=None, target=None, turn_id=None, history=False, at=None):
        """One Codex item into the main transcript, or into the transcript of the child
        `target`. `turn_id`, `history` and `at` (the record's time) only describe the
        children an item names; history leaves a child that looks live unknown."""
        kind=item.get('type'); item_id=item.get('id')
        if not kind or not item_id: return
        stamp=(timestamp/1000 if isinstance(timestamp,(int,float)) and timestamp>100000000000 else timestamp) or time.time()
        store=self.codex_target_parts(target)
        if target is not None and not completed and kind in ('agentMessage','reasoning','plan') and not any(
                item.get(key) for key in ('text','content','summary')):
            return  # A child's reply is shown complete; its deltas are not followed.
        if kind=='subAgentActivity':
            # A child report of an unexpected shape must never stop the main stream.
            self.subagent_guard(self.codex_activity,item,stamp,target,turn_id,history,epoch_seconds(at) or stamp); return
        if kind=='userMessage' and target is not None:
            text=''.join(part.get('text','') for part in item.get('content') or [] if part.get('type')=='text')
            self.codex_write(target,{'role':'user','content':text,'timestamp':stamp},'codex:'+item_id); return
        if kind=='userMessage':
            text=''.join(part.get('text','') for part in item.get('content') or [] if part.get('type')=='text')
            identity=item.get('clientId') or 'codex:'+item_id
            receipt=self.state.get('requests',{}).get(identity)
            if receipt:
                receipt['runtimeId']=item_id
                if receipt.get('mode')=='steer': receipt.update(status='consumed',error=None)
                elif receipt.get('status') in ('submitting','submitted','accepted'): receipt['status']='running'
            # A prompt recorded at send time already carries its attachment marks;
            # Codex echoes the same user message without them, so only foreign or
            # hydrated messages are imported here.
            if identity not in self.message_indices:
                self.upsert({'role':'user','content':text,'timestamp':stamp},identity)
            return
        if kind=='agentMessage':
            if completed or item.get('text'):
                text=item.get('text',''); store[item_id]={'text':text}
            else: text=(store.get(item_id) or {}).get('text','')
            self.codex_write(target,{'role':'assistant','content':[{'type':'text','text':text}],'timestamp':stamp},'codex:'+item_id)
            return
        if kind in ('reasoning','plan'):
            if completed or kind=='plan' or item.get('content') or item.get('summary'):
                if kind=='plan': parts={'summary':{},'content':{0:item.get('text','')}}
                else:
                    parts={'summary':{i:text for i,text in enumerate(item.get('summary') or [])},
                           'content':{i:text for i,text in enumerate(item.get('content') or [])}}
                store[item_id]=parts
            self.codex_upsert_reasoning(item_id,completed,stamp,kind=='reasoning',target)
            return
        tool_name=None; tool_input={}; output=None; failed=False
        if kind=='commandExecution':
            tool_name='shell'; tool_input={'command':item.get('command',''),'cwd':item.get('cwd','')}
            output=item.get('aggregatedOutput')
            if output is None and target is None: output=self.codex_outputs.get(item_id)
            failed=item.get('status') in ('failed','declined')
        elif kind=='fileChange':
            tool_name='apply_patch'; tool_input={'changes':item.get('changes') or []}
            if completed: output='文件修改'+('已完成' if item.get('status')=='completed' else '失败：'+str(item.get('status')))
            failed=item.get('status') in ('failed','declined')
        elif kind=='mcpToolCall':
            tool_name=(item.get('server','mcp')+'/'+item.get('tool','tool')).strip('/')
            tool_input=item.get('arguments') if item.get('arguments') is not None else {}
            output=item.get('result') if item.get('result') is not None else item.get('error')
            failed=item.get('status')=='failed' or item.get('error') is not None
        elif kind=='dynamicToolCall':
            tool_name='/'.join(x for x in (item.get('namespace'),item.get('tool')) if x) or 'tool'
            tool_input=item.get('arguments') if item.get('arguments') is not None else {}
            output=item.get('contentItems'); failed=item.get('status')=='failed' or item.get('success') is False
        elif kind=='webSearch':
            tool_name='web_search'; tool_input={'query':item.get('query',''),'action':item.get('action')}
            output=item.get('results')
        elif kind=='functionCallOutput':
            tool_name='/'.join(x for x in (item.get('namespace'),item.get('name')) if x) or 'function'
            output=item.get('output')
        elif kind=='collabAgentToolCall':
            tool_name='agent/'+str(item.get('tool','tool')); tool_input={'prompt':item.get('prompt'),'receivers':item.get('receiverThreadIds') or []}
            output=item.get('agentsStates'); failed=item.get('status') in ('failed','interrupted')
        elif kind=='imageView':
            tool_name='view_image'; tool_input={'path':item.get('path')}; output=item.get('path')
        elif kind=='imageGeneration':
            tool_name='image_generation'; output=item.get('result') or item.get('failure'); failed=item.get('failure') is not None
        else: return
        if target is not None and not history: self.codex_child_tool(target,item_id,tool_name)
        self.codex_write(target,{'role':'assistant','content':[{'type':'toolCall','id':item_id,'name':tool_name,'arguments':tool_input}],'timestamp':stamp},'codex-tool:'+item_id)
        if completed or output is not None:
            self.codex_write(target,{'role':'toolResult','toolCallId':item_id,'content':self.codex_text(output),'isError':failed,'timestamp':stamp},'codex-result:'+item_id)
        if kind=='collabAgentToolCall':
            self.subagent_guard(self.codex_collab,item,target,turn_id,history,epoch_seconds(at) or stamp)
    def codex_question_interaction(self, interaction_id, method, params):
        questions=[]; mapping={}
        def unique_label(value):
            base=value or '问题'; shown=base; suffix=2
            while shown in mapping:
                shown='%s (%d)' % (base,suffix); suffix+=1
            return shown
        if method=='item/tool/requestUserInput':
            for question in params.get('questions') or []:
                shown=unique_label(question.get('question') or question.get('id'))
                questions.append({'id':question.get('id'),'header':question.get('header',''),'question':shown,
                                  'options':question.get('options') or []})
                mapping[shown]={'id':question.get('id'),'type':'string'}
        else:
            schema=params.get('requestedSchema') or {}
            for name,field in (schema.get('properties') or {}).items():
                shown=unique_label(field.get('title') or field.get('description') or name)
                raw_options=field.get('enum') or ((field.get('items') or {}).get('enum'))
                titled=field.get('oneOf') or ((field.get('items') or {}).get('anyOf')) or []
                options=[{'label':str(value),'description':''} for value in (raw_options or [])]
                options += [{'label':str(value.get('title') or value.get('const')),'description':''} for value in titled]
                questions.append({'id':name,'header':params.get('serverName','MCP'),'question':shown,'options':options})
                mapping[shown]={'id':name,'type':field.get('type','string')}
        self.codex_interactions[interaction_id]['questions']=mapping
        return {'id':interaction_id,'name':'AskUserQuestion','title':params.get('message') or 'Codex 请求输入',
                'input':{'questions':questions}}
    def codex_frame(self, client, frame):
        with LOCK:
            if client is not self.codex or self.deleted:
                if 'id' in frame:
                    try: client.respond(frame['id'],error={'code':-32000,'message':'session is no longer attached'})
                    except Exception: pass
                return
            method=frame.get('method'); params=frame.get('params') or {}
            thread_id=params.get('threadId') or params.get('conversationId')
            if thread_id and self.state.get('resume') and thread_id!=self.state['resume']:
                # A registered child's requests become labelled interactions; any
                # other thread's are refused as before. Its notifications go to its
                # own transcript, or wait for the thread to register.
                if 'id' in frame:
                    entry=self.codex_child(thread_id)
                    if entry is None: client.respond(frame['id'],error={'code':-32602,'message':'thread id does not match this session'})
                    else: self.codex_request(client,frame,method,params,entry)
                    return
                self.subagent_guard(self.codex_child_frame,frame,thread_id)
                return
            if 'id' in frame:
                self.codex_request(client,frame,method,params); return
            if method=='thread/started':
                self.subagent_guard(self.codex_thread_started,params.get('thread') or {}); return
            if method=='turn/started':
                turn=params.get('turn') or {}; turn_id=turn.get('id')
                if turn_id: self.state['turnId']=turn_id
                self.state['busy']=True; self.state['error']=None; self.state['updated']=time.time(); self.finish('running'); self.touch(True); return
            if method=='turn/completed':
                turn=params.get('turn') or {}; status=turn.get('status'); error=turn.get('error') or {}
                # Children run their own turns, so their pending requests stay.
                self.state['busy']=False; self.state['updated']=time.time()
                self.state['interactions']=[x for x in self.state['interactions'] if isinstance(x.get('subagent'),dict)]
                self.codex_interactions={k:v for k,v in self.codex_interactions.items() if v.get('thread')}
                self.subagent_guard(self.subagent_flush)
                if status=='interrupted': self.state['cancelled']=True; self.state['stopAcknowledged']=True
                elif status=='failed': self.state['error']=error.get('message') if isinstance(error,dict) else str(error)
                elif not self.state.get('cancelled') and not self.state.get('error'): self.state['completed']+=1
                self.finish('stopped' if status=='interrupted' else 'failed' if status=='failed' else 'completed')
                for receipt in self.state.get('requests',{}).values():
                    if receipt.get('mode')=='steer' and receipt.get('turnId')==turn.get('id') and receipt['status'] in ('submitted','accepted'):
                        receipt.update(status='unknown',error='本轮已结束，尚未观察到引导消息进入上下文')
                self.touch(True); return
            if method in ('item/started','item/completed'):
                if method == 'item/started' and (params.get('item') or {}).get('type') == 'contextCompaction':
                    self.state['context'] = None
                key='completedAtMs' if method=='item/completed' else 'startedAtMs'
                # The turn only places the children an item names in the roster.
                self.codex_item(params.get('item') or {},method=='item/completed',params.get(key),
                                turn_id=params.get('turnId') or self.state.get('turnId')); self.touch(method=='item/completed'); return
            if method=='item/agentMessage/delta':
                item_id=params.get('itemId'); part=self.codex_parts.setdefault(item_id,{'text':''})
                part['text']=part.get('text','')+params.get('delta','')
                self.upsert({'role':'assistant','content':[{'type':'text','text':part['text']}],'timestamp':time.time()},'codex:'+str(item_id)); self.touch(); return
            if method=='item/plan/delta':
                item_id=params.get('itemId'); part=self.codex_parts.setdefault(item_id,{'summary':{},'content':{}})
                part.setdefault('content',{})[0]=part.setdefault('content',{}).get(0,'')+params.get('delta','')
                self.codex_upsert_reasoning(item_id,native_summary=False); self.touch(); return
            if method=='item/reasoning/summaryPartAdded':
                item_id=params.get('itemId'); part=self.codex_parts.setdefault(item_id,{'summary':{},'content':{}})
                part.setdefault('summary',{}).setdefault(params.get('summaryIndex',0),'')
                self.codex_upsert_reasoning(item_id); self.touch(); return
            if method in ('item/reasoning/textDelta','item/reasoning/summaryTextDelta'):
                item_id=params.get('itemId'); part=self.codex_parts.setdefault(item_id,{'summary':{},'content':{}})
                key='summary' if method.endswith('summaryTextDelta') else 'content'
                index=params.get('summaryIndex',0) if key=='summary' else params.get('contentIndex',0)
                part.setdefault(key,{})[index]=part.setdefault(key,{}).get(index,'')+params.get('delta','')
                self.codex_upsert_reasoning(item_id); self.touch(); return
            if method=='item/commandExecution/outputDelta':
                item_id=params.get('itemId'); self.codex_outputs[item_id]=self.codex_outputs.get(item_id,'')+params.get('delta','')
                self.upsert({'role':'toolResult','toolCallId':item_id,'content':self.codex_outputs[item_id],'isError':False,'timestamp':time.time()},'codex-result:'+str(item_id)); self.touch(); return
            if method=='thread/tokenUsage/updated':
                usage=params.get('tokenUsage') or {}; last=usage.get('last') or {}
                # total is cumulative across requests, not the active context window.
                self.state['context']={'tokens':last.get('totalTokens'),'limit':usage.get('modelContextWindow'),
                                       'reportedAt':time.time()}; self.touch(); return
            if method=='serverRequest/resolved': self.codex_resolved(params)
    def codex_request(self, client, frame, method, params, entry=None):
        """A server request: an approval or question for the user, raised by the main
        thread or, labelled with it, by the registered child `entry`."""
        approvals=('item/commandExecution/requestApproval','item/fileChange/requestApproval',
                   'item/permissions/requestApproval','execCommandApproval','applyPatchApproval')
        questions=('item/tool/requestUserInput','mcpServer/elicitation/request')
        if method not in approvals+questions:
            client.respond(frame['id'],error={'code':-32601,'message':'unsupported by the Perch bridge'})
            return
        interaction_id='codex-request-'+str(frame['id'])
        pending={'wireId':frame['id'],'method':method,'params':params}
        if entry is not None: pending['thread']=entry['id']
        self.codex_interactions[interaction_id]=pending
        if method in questions and not (method=='mcpServer/elicitation/request' and params.get('mode')=='url'):
            interaction=self.codex_question_interaction(interaction_id,method,params)
        else:
            if method in ('item/commandExecution/requestApproval','execCommandApproval'):
                command=params.get('command') or []
                if isinstance(command,list): command=' '.join(command)
                name='shell'; value={'command':command,'cwd':params.get('cwd'),'reason':params.get('reason')}
            elif method in ('item/fileChange/requestApproval','applyPatchApproval'):
                name='apply_patch'; value={'itemId':params.get('itemId') or params.get('callId'),'reason':params.get('reason'),
                                          'grantRoot':params.get('grantRoot'),'changes':params.get('fileChanges')}
            elif method=='item/permissions/requestApproval':
                name='request_permissions'; value={'cwd':params.get('cwd'),'reason':params.get('reason'),'permissions':params.get('permissions')}
            else:
                name='mcp_elicitation'; value={'server':params.get('serverName'),'message':params.get('message'),'url':params.get('url')}
            interaction={'id':interaction_id,'type':'interaction','name':name,'title':'Codex 请求确认','input':value}
        if entry is not None: interaction['subagent']=subagent_label(entry['id'],entry)
        self.state['interactions'].append(interaction); self.touch(True)
    def codex_resolved(self, params):
        wire_id=params.get('requestId')
        ids=[key for key,value in self.codex_interactions.items() if value.get('wireId')==wire_id]
        for key in ids: self.codex_interactions.pop(key,None)
        if ids:
            self.state['interactions']=[x for x in self.state['interactions'] if x.get('id') not in ids]; self.touch(True)
    def codex_answer(self, interaction_id, body):
        pending=self.codex_interactions.get(interaction_id)
        if not pending: raise ValueError('该 Codex 请求已失效，请同步会话后重试')
        method=pending['method']; params=pending['params']; allow=bool(body.get('allow')) and not body.get('cancelled')
        if method=='item/tool/requestUserInput':
            values=body.get('answers') or {}; answers={}
            for shown,question in pending.get('questions',{}).items():
                if shown not in values: raise ValueError('请回答所有问题')
                answers[question['id']]={'answers':[str(values[shown])]}
            result={'answers':answers}
        elif method=='mcpServer/elicitation/request':
            if not allow: result={'action':'decline'}
            elif params.get('mode')=='url': result={'action':'accept'}
            else:
                values=body.get('answers') or {}; content={}
                for shown,question in pending.get('questions',{}).items():
                    if shown not in values: raise ValueError('请回答所有问题')
                    value=values[shown]; kind=question['type']
                    if kind=='boolean': value=str(value).lower() in ('true','yes','1','是')
                    elif kind=='integer': value=int(value)
                    elif kind=='number': value=float(value)
                    elif kind=='array': value=[x.strip() for x in str(value).split(',') if x.strip()]
                    content[question['id']]=value
                result={'action':'accept','content':content}
        elif method in ('item/commandExecution/requestApproval','item/fileChange/requestApproval'):
            result={'decision':'accept' if allow else 'decline'}
        elif method=='item/permissions/requestApproval':
            result={'permissions':params.get('permissions') if allow else {},'scope':'turn'}
        else:
            result={'decision':'approved' if allow else {'denied':{'rejection':'用户在 Perch 中拒绝了该操作'}}}
        self.codex.respond(pending['wireId'],result=result)
        self.codex_interactions.pop(interaction_id,None)
        self.state['interactions']=[x for x in self.state['interactions'] if x.get('id')!=interaction_id]
        self.touch(True)
    def codex_exit(self, client, failure):
        with LOCK:
            if client is not self.codex: return
            self.codex=None; self.codex_attached=False
            if self.deleted or not failure: return
            self.state['error']=failure
            if self.state['busy']:
                self.finish('unknown'); self.state['busy']=False
            # Children ran inside that app-server and ended with it, unobserved.
            self.codex_pending=[]; self.subagent_guard(self.subagent_settle,'unknown')
            self.state['interactions']=[]; self.codex_interactions={}; self.touch(True)

    # Codex child threads. A spawned agent runs in a thread of its own on this
    # connection; its roster entry is keyed by that thread id (kind "codex") and its
    # frames build its own transcript. The main thread's state is never touched by them.
    def codex_child(self, thread_id):
        entry=self.subagent_entries.get(thread_id) if isinstance(thread_id,str) else None
        return entry if entry is not None and entry.get('kind')=='codex' else None
    def codex_register(self, thread_id, status=None, history=False, at=None, turn=None, alias=None,
                       card=None, parent=None, values=None, fill=None):
        """Registers the child `thread_id` on first sight and applies one report on it.
        A live `status` only describes a child the report creates (the child's own
        turn/started marks it running again later); a terminal one ends a live or
        unknown entry. History describes children no process runs any more, so one
        it shows live is unknown. `values` replace fields, `fill` sets unknown ones.
        Frames that waited for the thread are replayed once it registers."""
        if not isinstance(thread_id,str) or not thread_id or thread_id==self.state.get('resume'): return None
        entry=self.subagent_entries.get(thread_id)
        if entry is not None and entry.get('kind')!='codex': return None
        created=entry is None; ended=False
        if created:
            entry=self.subagent_create(thread_id,thread_id,kind='codex')
            opened=iso_time(at) if at else entry['startedAt']
            live=status is None or status in SUBAGENT_LIVE
            state=('unknown' if history else status or 'running') if live else status
            entry.update(turnId=None,parentTurnId=turn,startedAt=opened,updatedAt=opened,status=state,
                         endedAt=None if state in SUBAGENT_LIVE else opened)
        elif (status is not None and status not in SUBAGENT_LIVE and status!=entry['status']
              and (entry['status'] in SUBAGENT_LIVE or entry['status']=='unknown')):
            entry.update(status=status,endedAt=iso_time(at) if at else iso_time()); ended=True
        changed=created or ended
        if alias: changed=self.subagent_adopt(entry,tool_use_id=alias) or changed
        if card and not entry.get('cardId'): entry.update(cardId=card,cardParent=parent); changed=True
        changed=self.subagent_set(entry,**(values or {})) or changed
        changed=self.subagent_set(entry,**{k:v for k,v in (fill or {}).items() if entry.get(k) is None}) or changed
        if changed:
            self.subagent_bump(entry)
            if entry['status'] not in SUBAGENT_LIVE and (created or ended): self.subagent_write(entry['id']); self.subagent_keep(entry)
            self.subagent_relabel()
            # A history pass is published by its caller, once.
            if not history: self.touch(ended)
        if created: self.codex_replay(thread_id)
        return entry
    def codex_activity(self, item, stamp, target, turn, history, when):
        """subAgentActivity: the parent's record of a child it started, sent input to,
        interrupted or saw complete. A start shows in the parent's transcript as an
        agent/spawnAgent call, which that child's completion or interruption answers."""
        kind=item.get('kind'); item_id=item['id']
        path=item.get('agentPath') if isinstance(item.get('agentPath'),str) and item['agentPath'].strip() else None
        model=codex_text_value(item.get('model'))
        if kind=='started':
            self.codex_write(target,{'role':'assistant','content':[{'type':'toolCall','id':item_id,'name':'agent/spawnAgent',
                                     'arguments':{'agentPath':path,'model':model}}],'timestamp':stamp},'codex-tool:'+item_id)
        if kind not in ('started','interacted','interrupted','completed'): return
        started=kind=='started'
        entry=self.codex_register(item.get('agentThreadId'),CODEX_ACTIVITY_STATUS.get(kind,'running'),history,when,
                                  target['parentTurnId'] if target is not None else turn,
                                  alias=item_id if started else None,card=item_id if started else None,
                                  parent=target['id'] if target is not None else None,
                                  values={'description':codex_agent_name(path),'subagentType':clip_chars(path,200)},
                                  fill={'model':model})
        if entry is None: return
        if kind=='interacted' and history and entry['status'] not in SUBAGENT_LIVE and entry['status']!='unknown':
            # Input sent later ran the child again; history does not say how that ended.
            entry.update(status='unknown',endedAt=None); self.subagent_bump(entry)
        if kind in CODEX_ACTIVITY_STATUS: self.codex_card_result(entry)
    def codex_collab(self, item, target, turn, history, when):
        """collabAgentToolCall: its receivers and agentsStates name children; a
        spawnAgent call is an alias of the child it started."""
        states=item.get('agentsStates') if isinstance(item.get('agentsStates'),dict) else {}
        receivers=[x for x in item.get('receiverThreadIds') or [] if isinstance(x,str)]
        spawn=item.get('tool')=='spawnAgent'
        for thread_id in dict.fromkeys(receivers+[x for x in states if isinstance(x,str)]):
            if thread_id==item.get('senderThreadId'): continue
            state=states.get(thread_id) if isinstance(states.get(thread_id),dict) else {}
            status=CODEX_AGENT_STATUS.get(state.get('status')); message=clip_chars(state.get('message'),600)
            fill={'model':codex_text_value(item.get('model'))}
            if spawn: fill['description']=subagent_call({'prompt':item.get('prompt')})['description']
            entry=self.codex_register(thread_id,status,history,when,target['parentTurnId'] if target is not None else turn,
                                      alias=item.get('id') if spawn else None,fill=fill,
                                      values={'summary':message} if status=='completed' else {'error':message} if status=='failed' else None)
            if entry is not None and status in ('completed','stopped','failed'): self.codex_card_result(entry)
    def codex_thread_started(self, thread):
        """A thread whose parent is this session's thread, or one of its children."""
        parent=thread.get('parentThreadId'); owner=self.codex_child(parent)
        if not parent or (parent!=self.state.get('resume') and owner is None): return
        self.codex_register(thread.get('id'),'running',turn=owner['parentTurnId'] if owner else self.state.get('turnId'),
                            fill={'description':clip_chars(thread.get('agentNickname'),200),
                                  'subagentType':codex_text_value(thread.get('agentRole')),'model':codex_text_value(thread.get('model'))})
    def codex_card_result(self, entry):
        """Answers the agent/spawnAgent call that started a child, once it ended."""
        card=entry.get('cardId'); status=entry.get('status'); parent=entry.get('cardParent')
        if not card or status not in ('completed','stopped','failed'): return
        target=self.codex_child(parent) if parent else None
        if parent and target is None: return
        text=entry.get('summary') if status=='completed' else entry.get('error') if status=='failed' else None
        text=text or {'completed':'子 Agent 已完成','stopped':'子 Agent 已停止','failed':'子 Agent 失败'}[status]
        self.codex_write(target,{'role':'toolResult','toolCallId':card,'content':text,'isError':status!='completed',
                                 'timestamp':iso_seconds(entry.get('endedAt'))},'codex-result:'+card)
    def codex_usage(self, entry):
        usage=entry.get('usage')
        return dict(usage) if isinstance(usage,dict) else {'totalTokens':0,'toolUses':0,'durationMs':0}
    def codex_child_tool(self, entry, item_id, name):
        usage=self.codex_usage(entry)
        if item_id not in self.subagent_transcript(entry)['tools']: usage['toolUses']+=1
        if self.subagent_set(entry,usage=usage,lastToolName=name): self.subagent_bump(entry); self.touch()
    def codex_child_frame(self, frame, thread_id):
        """A notification of a child thread. Complete items are enough for its
        transcript, so streaming deltas, hooks and status pings are not followed."""
        method=frame.get('method'); params=frame.get('params') or {}
        if method not in CODEX_CHILD_METHODS: return
        entry=self.codex_child(thread_id)
        if entry is None:
            now=time.monotonic()
            pending=[x for x in self.codex_pending if now-x[0]<=CODEX_PENDING_SECONDS]
            self.codex_pending=pending[-(CODEX_PENDING_LIMIT-1):]+[(now,thread_id,frame)]
            return
        if method in ('item/started','item/completed'):
            key='completedAtMs' if method=='item/completed' else 'startedAtMs'
            self.codex_item(params.get('item') or {},method=='item/completed',params.get(key),target=entry,turn_id=params.get('turnId'))
        elif method=='turn/started': self.codex_child_turn(entry,params.get('turn') or {})
        elif method=='turn/completed': self.codex_child_done(entry,params.get('turn') or {})
        elif method=='thread/tokenUsage/updated':
            # total is what the child used so far; last, the main thread's window
            # reading, covers one request only.
            total=((params.get('tokenUsage') or {}).get('total') or {}).get('totalTokens')
            if isinstance(total,int) and not isinstance(total,bool):
                usage=self.codex_usage(entry); usage['totalTokens']=total
                if self.subagent_set(entry,usage=usage): self.subagent_bump(entry); self.touch()
        else: self.codex_resolved(params)
    def codex_replay(self, thread_id):
        now=time.monotonic(); keep=[]; replay=[]
        for x in self.codex_pending:
            if now-x[0]<=CODEX_PENDING_SECONDS: (replay if x[1]==thread_id else keep).append(x)
        self.codex_pending=keep
        for _,_,frame in replay: self.subagent_guard(self.codex_child_frame,frame,thread_id)
    def codex_child_turn(self, entry, turn):
        turn_id=turn.get('id')
        if not isinstance(turn_id,str) or not turn_id: return
        live=entry['status'] in SUBAGENT_LIVE
        # A late copy of a turn that already ended never revives its entry; a new
        # turn (the parent sent it input) does.
        if turn_id==entry['turnId'] and not live: return
        changed=self.subagent_set(entry,turnId=turn_id,status='running')
        # A new run starts clean; its summary is replaced once it ends.
        if not live: entry.update(endedAt=None,error=None,stopRequested=False,stopError=None)
        root=turn.get('rootTurnId')
        if isinstance(root,str) and root: changed=self.subagent_set(entry,parentTurnId=root) or changed
        if changed: self.subagent_bump(entry); self.touch()
    def codex_child_done(self, entry, turn):
        """The child's turn ended: its status, summary and usage, never the main turn's.
        Applied once per turn, also when the parent's report ended the entry first."""
        status=CODEX_TURN_STATUS.get(turn.get('status')); turn_id=turn.get('id')
        turn_id=turn_id if isinstance(turn_id,str) and turn_id else None
        if status is None or (entry['turnId'] and turn_id and turn_id!=entry['turnId']): return
        if turn_id and entry.get('doneTurn')==turn_id: return
        # The child's own pending requests end with its turn; the main thread's stay.
        ids=[k for k,v in self.codex_interactions.items() if v.get('thread')==entry['id']]
        for k in ids: self.codex_interactions.pop(k,None)
        if ids: self.state['interactions']=[x for x in self.state['interactions'] if x.get('id') not in ids]
        self.codex_child_parts.pop(entry['id'],None)
        usage=self.codex_usage(entry); duration=turn.get('durationMs')
        if isinstance(duration,(int,float)) and not isinstance(duration,bool) and duration>0:
            usage['durationMs']+=int(duration)
        error=turn.get('error'); error=error.get('message') if isinstance(error,dict) else error
        ended=epoch_seconds(turn.get('completedAt'))
        self.subagent_set(entry,turnId=turn_id,usage=usage,summary=self.codex_child_text(entry,turn),
                          error=clip_chars(error,600) if status=='failed' else None)
        entry.update(status=status,endedAt=iso_time(ended) if ended else iso_time(),doneTurn=turn_id)
        self.subagent_bump(entry); self.subagent_write(entry['id']); self.subagent_keep(entry)
        self.codex_card_result(entry); self.subagent_relabel(); self.touch(True)
    def codex_child_text(self, entry, turn):
        """The child's last reply: the one its turn reports, else its transcript's last text."""
        for item in reversed(turn.get('items') or []):
            if isinstance(item,dict) and item.get('type')=='agentMessage' and clip_chars(item.get('text'),600):
                return clip_chars(item['text'],600)
        transcript=self.subagent_transcripts.get(entry['id'])
        for message in reversed(transcript['messages'] if transcript else []):
            if message['role']!='assistant': continue
            for part in reversed(message['content']):
                if part.get('type')=='text' and clip_chars(part.get('text'),600): return clip_chars(part['text'],600)
        return None
    def codex_backfill_plan(self, key):
        """A child whose transcript is missing or empty (after a restart, or known only
        from history) is read once from the runtime's own record of its thread."""
        entry=self.subagent_find(key)
        if entry is None or entry.get('kind')!='codex' or self.deleted: return None
        key=entry['id']; mark=self.codex_backfills.get(key)
        if mark is True or mark=='reading' or (isinstance(mark,float) and time.monotonic()<mark): return None
        if self.subagent_transcript(entry)['messages']: self.codex_backfills[key]=True; return None
        self.codex_backfills[key]='reading'
        live=self.codex if self.codex and self.codex.process.poll() is None else None
        return {'key':key,'client':live,'cwd':self.state['cwd'],'home':self.state.get('codexHome')}
    def codex_backfill(self, plan):
        """Runs outside the lock: pages the child's items oldest first, as the probe
        read them, keeping the newest up to the transcript's message cap. Without a
        live app-server a short-lived one reads them, as model discovery does."""
        items=[]; dropped=0; client=plan['client']; own=None
        try:
            if client is None:
                own=client=CodexAppServer(plan['cwd'],home=plan['home']); client.initialize()
            cursor=None
            for _ in range(CODEX_BACKFILL_PAGES):
                params={'threadId':plan['key'],'sortDirection':'asc','limit':100}
                if cursor: params['cursor']=cursor
                page=client.request('thread/items/list',params)
                items.extend(x for x in page.get('data') or [] if isinstance(x,dict))
                if len(items)>SUBAGENT_MESSAGE_LIMIT:
                    dropped+=len(items)-SUBAGENT_MESSAGE_LIMIT; items=items[-SUBAGENT_MESSAGE_LIMIT:]
                cursor=page.get('nextCursor')
                if not cursor: break
        except Exception: items=None
        finally:
            if own is not None: own.close()
        with LOCK: self.subagent_guard(self.codex_backfill_install,plan['key'],items,dropped)
    def codex_backfill_install(self, key, items, dropped):
        if items is None: self.codex_backfills[key]=time.monotonic()+CODEX_BACKFILL_RETRY; return
        self.codex_backfills[key]=True
        entry=self.codex_child(key)
        # Live frames that filled the transcript meanwhile are newer than this read.
        if entry is None or self.deleted or self.subagent_transcript(entry)['messages']: return
        for record in items:
            self.codex_item(record.get('item') or {},True,record.get('completedAtMs') or record.get('startedAtMs'),
                            target=entry,turn_id=record.get('turnId'),history=True)
        if dropped: self.subagent_transcript(entry)['truncated']+=dropped
        self.subagent_write(key); self.touch()
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
                self.state['busy'] = False; self.state['interactions'] = []; self.subagent_guard(self.subagent_settle); self.touch(True)
    def upsert(self, message, identity):
        value = copy.deepcopy(normalize(message,identity))
        index = self.message_indices.get(identity)
        if index is None:
            index = len(self.state['messages']); self.message_indices[identity] = index
            self.state['messages'].append(value)
            if is_user_prompt(value): self.prompt_indices.append(index)
        else:
            old = self.state['messages'][index]
            if old == value: return
            if is_user_prompt(old) and not is_user_prompt(value): self.prompt_indices.remove(index)
            if not is_user_prompt(old) and is_user_prompt(value): bisect.insort(self.prompt_indices, index)
            self.state['messages'][index] = value
        self.message_versions[index] = self.state['revision'] + 1
    def steer(self, body):
        s=self.state; request_id=body.get('requestId'); text=body.get('text','')
        if s['provider'] not in ('omp','codex'): raise ValueError('当前 Agent 不支持运行中引导')
        if body.get('attachments'): raise ValueError('运行中引导不支持附件，请等待当前轮结束后再发送')
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
        receipt={'id':request_id,'digest':digest,'text':text,'status':'submitting',
                 'mode':'steer','turnId':s.get('turnId')}
        receipts[request_id]=receipt
        if s['provider']=='codex': self.upsert({'role':'user','content':text},request_id)
        self.touch(True)
        try:
            if s['provider']=='codex':
                self.codex_ensure(True)
                self.codex.request('turn/steer',{'threadId':s['resume'],'expectedTurnId':s['turnId'],
                                                 'input':[{'type':'text','text':text}],
                                                 'clientUserMessageId':request_id})
                receipt['status']='accepted'
            else:
                self.send({'type':'steer','id':request_id,'message':text}); receipt['status']='submitted'
        except Exception as e: receipt.update(status='unknown',error=str(e))
        self.touch(True)
        return copy.deepcopy(receipt)

    def event(self,e):
        s = self.state; t = e.get('type'); provider = s['provider']; durable = False
        # Child messages belong to the Agent tool, whose result remains visible.
        # They must not create main-session turns or replace its streaming tail, so
        # they go to that subagent's own transcript; child stream events are dropped.
        if provider == 'claude' and t in ('assistant', 'user', 'stream_event') and e.get('parent_tool_use_id'):
            if t != 'stream_event': self.subagent_guard(self.subagent_message, e)
            return
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
            if provider == 'claude': s['contextTokens'] = None
        elif t == 'stop_ack' and e.get('turnId')==s.get('turnId'):
            s['stopAcknowledged']=True; durable=True
        elif t == 'agent_end':
            if e.get('isTerminal') is False: return
            if provider in ('qoder','qoderintl','claude') and s.get('stopAcknowledged'): s['cancelled']=True
            s['busy']=False; s['interactions']=[]; s['updated']=time.time(); durable=True
            if provider == 'claude': self.subagent_guard(self.subagent_settle)
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
        elif provider in ('qoder','qoderintl','claude') and t == 'interaction':
            e=copy.deepcopy(e)
            if provider=='claude':
                # Approvals raised inside a subagent name it; one the roster cannot
                # resolve yet keeps its agent id and is labelled once an event does.
                agent=e.pop('agentId',None)
                if agent: e['subagent']=subagent_label(agent,self.subagent_guard(self.subagent_resolve,agent,e.get('id')))
            if provider=='claude' and e.get('name')=='ExitPlanMode':
                content=e.get('planContent', (e.get('input') or {}).get('plan'))
                content=content if isinstance(content,str) else ''
                e['planReview']={'revision':uuid.uuid4().hex,'content':content,
                                 'complete':bool(content.strip()),'status':'awaiting_review','changed':e.get('planChanged') is True}
                # A replacement with the same tool ID invalidates the old revision.
                s['interactions']=[x for x in s['interactions'] if x['id']!=e['id']]
            s['interactions'].append(e); durable=True
        elif provider in ('qoder','qoderintl','claude') and t == 'interaction_cancel': s['interactions']=[x for x in s['interactions'] if x['id']!=e['id']]; durable=True
        elif provider in ('qoder','qoderintl','claude') and t in ('assistant','user'):
            message = e['message']
            if provider == 'claude' and t == 'user' and e.get('isSynthetic'):
                message = copy.deepcopy(message)
                message['content'] = text_parts(message.get('content'))
                for part in message['content']:
                    if part.get('type') == 'text': part['source'] = {'kind':'runtime_context','provider':'claude'}
            self.upsert(message, e.get('uuid') or message.get('id') or str(uuid.uuid4()))
            if provider == 'claude': self.subagent_guard(self.subagent_main, message)
            if provider == 'claude' and t == 'assistant':
                # Per-request usage of the latest main-loop reply: the live window
                # fill. result.usage is the turn total summed across API requests and
                # overstates the window whenever a turn makes more than one.
                u = message.get('usage') or {}
                tokens = u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)+u.get('output_tokens',0)
                if tokens: s['contextTokens'] = tokens
            if t == 'assistant' or provider in ('qoder','qoderintl'): s.pop('partial',None)
            durable=True
        elif provider in ('qoder','qoderintl','claude') and t == 'stream_event':
            ev=e['event']; et=ev['type']
            if provider == 'claude':
                # Claude emits a complete assistant message for EACH block,
                # before content_block_stop. API indices keep increasing after
                # that block has been committed, so they are not list offsets.
                if et == 'message_start':
                    s.pop('partial', None); self.sdk_block_index = None
                elif et == 'content_block_start':
                    self.sdk_block_index = ev.get('index', 0)
                    s['partial'] = {'role':'assistant','content':[copy.deepcopy(ev['content_block'])]}
                elif et == 'content_block_delta' and s.get('partial') and ev['index'] == self.sdk_block_index:
                    delta = ev['delta']; part = s['partial']['content'][0]
                    if delta['type'] == 'text_delta': part['text'] = part.get('text','') + delta['text']
                    elif delta['type'] == 'thinking_delta': part['thinking'] = part.get('thinking','') + delta['thinking']
                    else: return
                elif et == 'message_stop':
                    s.pop('partial', None); self.sdk_block_index = None
                else: return
            else:
                if et=='message_start': s['partial']={'role':'assistant','content':[]}
                elif et=='content_block_start':
                    s.setdefault('partial',{'role':'assistant','content':[]})['content'].append(ev['content_block'])
                elif et=='content_block_delta' and s.get('partial'):
                    idx=ev['index']; delta=ev['delta']; parts=s['partial']['content']
                    if idx<len(parts):
                        if delta['type']=='text_delta': parts[idx]['text']=parts[idx].get('text','')+delta['text']
                        elif delta['type']=='thinking_delta': parts[idx]['thinking']=parts[idx].get('thinking','')+delta['thinking']
                else: return
        elif provider in ('qoder','qoderintl','claude') and t == 'result':
            s['resume']=e.get('session_id',s.get('resume')); durable=True
            if e.get('is_error') and not s.get('cancelled') and not s.get('stopAcknowledged'): s['error']='\n'.join(e.get('errors',[])) or e.get('result',('Qoder' if provider in ('qoder','qoderintl') else 'Claude')+' 执行失败')
            if provider == 'claude':
                # Report the latest per-request reading, not result.usage: that field
                # is the turn total across API requests, not the window fill. A turn
                # without any assistant reply keeps the previous reading.
                windows=[m.get('contextWindow') for m in (e.get('modelUsage') or {}).values() if m.get('contextWindow')]
                tokens=s.get('contextTokens')
                if tokens and windows: s['context']={'tokens':tokens,'limit':max(windows),'reportedAt':time.time()}
        elif provider == 'claude' and t == 'context_usage':
            # The SDK's resolved autocompact window (e.g. the 200K policy boundary on
            # 1M models), not the model's declared limit; overrides the estimate above.
            if e.get('limit'):
                s['context']={'tokens':e.get('tokens'),'limit':e['limit'],'reportedAt':time.time()}; durable=True
        elif provider in ('qoder','qoderintl','claude') and t == 'system' and e.get('subtype')=='init': s['resume']=e.get('session_id'); s['model']=e.get('model',s['model']); durable=True
        elif provider == 'claude' and t == 'system' and e.get('subtype') in SUBAGENT_TASK_EVENTS:
            # background_tasks_changed is a level signal whose order against these
            # edges is unspecified, so it never decides a subagent's status.
            finished=self.subagent_guard(self.subagent_task, e)
            if finished is None: return
            durable=finished
        elif provider == 'claude' and t == 'task_stop_result':
            if not self.subagent_guard(self.subagent_stop_result, e): return
            durable=True
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
    def answer_plan(self, body):
        item=next((x for x in self.state['interactions'] if x['id']==body.get('id') and (not x.get('expires') or x['expires']>time.time())),None)
        plan=item.get('planReview') if item else None
        if not plan or body.get('planRevision')!=plan['revision']:
            raise PlanReviewConflict('计划已变化或已处理，请查看最新计划后再决定')
        decision=body.get('decision')
        if decision=='resume' and plan['status']=='deferred':
            plan['status']='awaiting_review'; self.touch(True); return
        if plan['status']!='awaiting_review':
            raise PlanReviewConflict('计划已暂缓，请先继续审批')
        if decision=='defer':
            plan['status']='deferred'; self.touch(True); return
        if decision not in ('approve','request_changes'):
            raise ValueError('未知的计划审批操作')
        feedback=body.get('feedback','')
        if not isinstance(feedback,str): raise ValueError('请填写修改意见')
        if decision=='request_changes' and not feedback.strip(): raise ValueError('请填写修改意见')
        if decision=='approve' and not plan['complete']:
            raise ValueError('尚未收到完整计划，请要求 Agent 补充后再批准')
        # Only the current request can be answered; deferring never resolves the SDK callback.
        self.send({'type':'answer','id':item['id'],'allow':decision=='approve',
                   'feedback':feedback.strip() if decision=='request_changes' else ''})
        self.state['planReviewHistory']=(self.state.get('planReviewHistory',[])+[
            {'id':item['id'],**plan,'status':decision,'feedback':feedback.strip()}])[-20:]
        self.state['interactions']=[x for x in self.state['interactions'] if x['id']!=item['id']]
        self.touch(True)

    def snapshot(self, revision=None, turns=None, start=None, epoch=None, before=None):
        live=[x for x in self.state['interactions'] if not x.get('expires') or x['expires']>time.time()]
        if live != self.state['interactions']: self.state['interactions']=live; self.touch(True)
        paged = turns is not None or start is not None or before is not None
        if not paged:
            if revision == str(self.state['revision']): return {'unchanged':True}
            s=copy.deepcopy({k:v for k,v in self.state.items() if k not in ('requests','subagentRoster')})
            s['permission']=permission_capability(self.state)
            if s.get('partial'): s['messages'].append(normalize(s.pop('partial'),'live'))
            s['subagents']=self.subagent_live()
            return s
        count = len(self.state['messages'])
        partial = normalize(self.state['partial'], 'live') if self.state.get('partial') else None
        total = count + (1 if partial else 0)
        limit = int(turns or 50)
        if not 1 <= limit <= 100: raise ValueError('Invalid history page size')
        if before is not None and epoch != self.history_epoch: raise ValueError('History changed; reopen the conversation')
        end = int(before) if before is not None else total
        if not 0 <= end <= total: raise ValueError('Invalid history cursor')
        if start is not None and epoch == self.history_epoch:
            first = int(start)
            if not 0 <= first <= end: raise ValueError('Invalid history cursor')
        else:
            prompts = bisect.bisect_left(self.prompt_indices, end)
            first = self.prompt_indices[prompts-limit] if prompts > limit else 0
        history = {'epoch':self.history_epoch, 'start':first, 'total':total, 'end':end}
        since = int(revision) if revision is not None else None
        delta = before is None and start is not None and epoch == self.history_epoch and since is not None and 0 <= since <= self.state['revision']
        if delta and since == self.state['revision']: return {'unchanged':True}
        # Copy metadata and only the requested page/changed messages. Completed
        # history is neither deep-copied nor serialized for every stream tick.
        s=copy.deepcopy({k:v for k,v in self.state.items() if k not in ('requests','messages','partial','subagentRoster')})
        s['permission']=permission_capability(self.state)
        if delta:
            indices = sorted(i for i, version in self.message_versions.items() if first <= i < count and version > since)
            if partial: indices.append(count)
            history.update(indices=indices, baseRevision=since)
        else: indices = range(first, end)
        s['messages'] = [copy.deepcopy(self.state['messages'][i]) if i < count else partial for i in indices]
        s['history'] = history
        s['subagents'] = self.subagent_live()
        return s

    # Subagents: Claude tasks and Codex child threads. Roster entries live in
    # state['subagentRoster'] and their changes touch() the session. Each transcript
    # keeps its own epoch, revision and per-index versions, so a busy child leaves
    # the main snapshot poll quiet.
    def index_subagents(self):
        self.subagent_entries = {}; self.subagent_aliases = {}
        for entry in self.state.get('subagentRoster') or []:
            self.subagent_entries[entry['id']] = entry
            for alias in [entry['id'], entry.get('taskId')] + list(entry.get('toolUseIds') or []):
                if alias: self.subagent_aliases.setdefault(alias, entry['id'])
    def subagent_guard(self, action, *args):
        # A child event of an unexpected shape must never stop the main stream.
        try: return action(*args)
        except Exception:
            traceback.print_exc()
            return None
    def subagent_find(self, alias):
        return self.subagent_entries.get(self.subagent_aliases.get(alias)) if alias else None
    def subagent_resolve(self, agent_id, tool_use_id=None):
        """The entry an approval came from: its agent id once that is an alias, or
        the transcript that already holds the tool call being approved."""
        entry = self.subagent_find(agent_id)
        if entry is None and tool_use_id:
            key = next((k for k, t in self.subagent_transcripts.items() if tool_use_id in t['tools']), None)
            entry = self.subagent_entries.get(key)
            if entry is not None and agent_id: self.subagent_aliases.setdefault(agent_id, entry['id'])
        return entry
    def subagent_relabel(self):
        changed = False
        for interaction in self.state['interactions']:
            label = interaction.get('subagent')
            if not isinstance(label, dict): continue
            entry = (self.subagent_entries.get(label['id']) if label.get('id')
                     else self.subagent_resolve(label.get('agentId'), interaction.get('id')))
            fresh = subagent_label(label.get('agentId'), entry)
            if fresh != label: interaction['subagent'] = fresh; changed = True
        return changed
    def subagent_named(self):
        return {x['subagent']['id'] for x in self.state['interactions'] if isinstance(x.get('subagent'), dict) and x['subagent'].get('id')}
    def subagent_adopt(self, entry, task_id=None, tool_use_id=None):
        changed = False
        if task_id and not entry['taskId']: entry['taskId'] = task_id; changed = True
        if tool_use_id and tool_use_id not in entry['toolUseIds']: entry['toolUseIds'].append(tool_use_id); changed = True
        for alias in (task_id, tool_use_id):
            if alias: self.subagent_aliases.setdefault(alias, entry['id'])
        return changed
    def subagent_set(self, entry, **values):
        # None means "not reported", which never erases what is already known.
        changed = False
        for key, value in values.items():
            if value is not None and entry.get(key) != value: entry[key] = value; changed = True
        return changed
    def subagent_bump(self, entry):
        # Entry changes also reach a client that follows the transcript.
        entry['revision'] += 1; entry['updatedAt'] = iso_time()
    def subagent_create(self, key, task_id=None, tool_use_id=None, kind='claude'):
        now = iso_time()
        entry = {'id':key, 'kind':kind, 'taskId':None, 'toolUseIds':[], 'turnId':self.state.get('turnId'),
                 'description':None, 'subagentType':None, 'status':'running', 'background':None,
                 'startedAt':now, 'updatedAt':now, 'endedAt':None, 'usage':None, 'lastToolName':None,
                 'summary':None, 'error':None, 'canStop':False, 'stopRequested':False, 'stopError':None,
                 'messageCount':0, 'revision':0}
        self.state.setdefault('subagentRoster', []).append(entry)
        self.subagent_entries[key] = entry; self.subagent_aliases[key] = key
        self.subagent_adopt(entry, task_id, tool_use_id)
        self.subagent_set(entry, **(self.subagent_calls.get(tool_use_id) or {}))
        self.subagent_transcripts[key] = subagent_transcript_state()
        self.subagent_prune()
        return entry
    def subagent_finish(self, entry, status, ended=None):
        entry['status'] = status; entry['endedAt'] = ended or iso_time()
        self.subagent_bump(entry); self.subagent_write(entry['id']); self.subagent_keep(entry)
    def subagent_prune(self):
        roster = self.state.get('subagentRoster') or []
        excess = len(roster) - SUBAGENT_ROSTER_LIMIT
        if excess <= 0: return
        # Only finished entries go, oldest first, never one a pending approval names.
        named = self.subagent_named()
        finished = sorted((x for x in roster if x['status'] not in SUBAGENT_LIVE and x['id'] not in named), key=lambda x: x['startedAt'])
        gone = {x['id'] for x in finished[:excess]}
        if not gone: return
        self.state['subagentRoster'] = [x for x in roster if x['id'] not in gone]
        self.subagent_aliases = {alias:key for alias, key in self.subagent_aliases.items() if key not in gone}
        for key in gone:
            self.subagent_entries.pop(key, None); self.subagent_transcripts.pop(key, None); self.subagent_dirty.discard(key)
            self.subagent_recent.pop(key, None); self.subagent_written.pop(key, None)
            try: self.subagent_path(key).unlink(missing_ok=True)
            except OSError: pass
    def subagent_view(self, entry):
        view = {key:entry.get(key) for key in SUBAGENT_KEYS}
        view['toolUseIds'] = list(entry.get('toolUseIds') or [])
        view['usage'] = dict(entry['usage']) if isinstance(entry.get('usage'), dict) else None
        view['stopRequested'] = bool(entry.get('stopRequested'))
        if entry.get('kind') == 'codex':
            # A Codex child's turnId is its own running turn, which turn/interrupt
            # names; the child may outlive the main turn.
            view['canStop'] = entry.get('status') == 'running' and bool(entry.get('turnId'))
        else:
            view['canStop'] = (entry.get('kind') == 'claude' and entry.get('status') in SUBAGENT_LIVE and bool(entry.get('taskId'))
                               and bool(self.state.get('busy')) and bool(self.state.get('turnId')))
        return view
    def subagent_live(self):
        roster = self.state.get('subagentRoster') or []
        if not roster: return []
        named = self.subagent_named(); turn = self.state.get('turnId'); ranked = []
        for position, entry in enumerate(roster):
            # A Codex child's turnId is its own; parentTurnId is the main turn it belongs to.
            owner = entry.get('parentTurnId') if entry.get('kind') == 'codex' else entry.get('turnId')
            rank = (0 if entry.get('id') in named else 1 if entry.get('status') in SUBAGENT_LIVE
                    else 2 if turn and owner == turn else None)
            if rank is not None: ranked.append((rank, entry.get('startedAt') or '', position, entry))
        # Over the cap, approvals and running children win over finished ones and
        # newer over older; the list itself reads in start order.
        ranked.sort(key=lambda x: (x[1], x[2]), reverse=True)
        ranked.sort(key=lambda x: x[0])
        return [self.subagent_view(x[3]) for x in sorted(ranked[:SUBAGENT_SNAPSHOT_LIMIT], key=lambda x: (x[1], x[2]))]
    def subagent_path(self, key):
        return ROOT / 'subagents' / self.state['id'] / subagent_filename(key)
    def subagent_transcript(self, entry):
        key = entry['id']; transcript = self.subagent_transcripts.get(key)
        if transcript is None:
            revision = 0; flushed = self.subagent_written.pop(key, None)
            try:
                data = json.loads(self.subagent_path(key).read_text())
                versions = {int(k):int(v) for k, v in (data.get('versions') or {}).items()}
                transcript = subagent_transcript_state(data['messages'], int(data.get('truncated') or 0), versions)
                revision = int(data.get('revision') or 0)
                # This service wrote the whole transcript before evicting it, so its
                # positions still hold. A file from an earlier service can lag what a
                # client already read; it restarts under a new epoch, as main history does.
                if flushed is not None and data.get('epoch') == flushed: transcript['epoch'] = flushed
            except Exception: transcript = subagent_transcript_state()
            entry['revision'] = max(entry['revision'], revision); entry['messageCount'] = len(transcript['messages'])
            self.subagent_transcripts[key] = transcript
        self.subagent_keep(entry)
        return transcript
    def subagent_keep(self, entry):
        """Live transcripts stay in memory; finished ones share a small LRU."""
        key = entry['id']; self.subagent_recent.pop(key, None)
        if entry['status'] in SUBAGENT_LIVE or key not in self.subagent_transcripts: return
        self.subagent_recent[key] = None
        for old in list(self.subagent_recent)[:-SUBAGENT_RECENT_LIMIT]: self.subagent_evict(old)
    def subagent_evict(self, key):
        # A transcript leaves memory only once its file holds all of it; while a
        # write fails it stays loaded.
        if (key in self.subagent_dirty or not self.subagent_path(key).exists()) and not self.subagent_write(key): return
        transcript = self.subagent_transcripts.pop(key, None); self.subagent_recent.pop(key, None)
        if transcript is not None: self.subagent_written[key] = transcript['epoch']
    def subagent_append(self, entry, value):
        transcript = self.subagent_transcript(entry)
        index = transcript['index'].get(value['id']); size = json_size(value)
        if index is None:
            index = len(transcript['messages']); transcript['index'][value['id']] = index
            transcript['messages'].append(value); transcript['sizes'].append(size); transcript['bytes'] += size
        elif transcript['messages'][index] == value: return False
        else:
            transcript['bytes'] += size - transcript['sizes'][index]
            transcript['messages'][index] = value; transcript['sizes'][index] = size
        entry['revision'] += 1; transcript['versions'][index] = entry['revision']
        transcript['tools'].update(p['tool_call_id'] for p in value['content'] if p.get('type') == 'tool_use')
        self.subagent_trim(transcript)
        entry['messageCount'] = len(transcript['messages']); entry['updatedAt'] = iso_time()
        self.subagent_mark(entry['id'])
        return True
    def subagent_trim(self, transcript):
        messages = transcript['messages']; sizes = transcript['sizes']
        if len(messages) <= SUBAGENT_MESSAGE_LIMIT and transcript['bytes'] <= SUBAGENT_BYTE_LIMIT: return
        drop = max(0, len(messages) - SUBAGENT_MESSAGE_LIMIT * 3 // 4); kept = transcript['bytes'] - sum(sizes[:drop])
        while drop < len(messages) - 1 and kept > SUBAGENT_BYTE_LIMIT * 3 // 4:
            kept -= sizes[drop]; drop += 1
        if not drop: return
        # Every position moves, so the transcript starts a new epoch.
        messages = messages[drop:]
        transcript.update(epoch=uuid.uuid4().hex, truncated=transcript['truncated'] + drop, messages=messages,
                          sizes=sizes[drop:], bytes=kept, versions={}, index={m['id']:i for i, m in enumerate(messages)},
                          tools={p.get('tool_call_id') for m in messages for p in m['content'] if p.get('type') == 'tool_use'})
    def subagent_mark(self, key):
        # A busy transcript is written about every two seconds; a finished entry
        # and the end of the turn write at once.
        self.subagent_dirty.add(key)
        if self.subagent_timer is None and not self.deleted:
            self.subagent_timer = threading.Timer(SUBAGENT_SAVE_DELAY, self.subagent_timer_fired)
            self.subagent_timer.daemon = True; self.subagent_timer.start()
    def subagent_timer_fired(self):
        with LOCK:
            self.subagent_timer = None; self.subagent_flush()
    def subagent_flush(self):
        for key in list(self.subagent_dirty): self.subagent_write(key)
    def subagent_write(self, key):
        entry = self.subagent_entries.get(key); transcript = self.subagent_transcripts.get(key)
        if self.deleted or entry is None or transcript is None: self.subagent_dirty.discard(key); return False
        try:
            folder = ROOT / 'subagents' / self.state['id']
            folder.parent.mkdir(exist_ok=True); folder.mkdir(exist_ok=True)
            save(folder / subagent_filename(key), {'epoch':transcript['epoch'], 'revision':entry['revision'],
                 'truncated':transcript['truncated'], 'messages':transcript['messages'], 'versions':transcript['versions']})
        except (OSError, ValueError): return False  # stays dirty; the next change or turn end retries
        self.subagent_dirty.discard(key)
        return True
    def subagent_discard(self):
        if self.subagent_timer is not None: self.subagent_timer.cancel(); self.subagent_timer = None
        self.subagent_dirty.clear(); self.subagent_transcripts.clear(); self.subagent_recent.clear(); self.subagent_written.clear()
        shutil.rmtree(ROOT / 'subagents' / self.state['id'], ignore_errors=True)
    def subagent_recover(self):
        """At service start the worker of a queued or running child is gone with the
        previous service, and a transcript no roster entry names is an orphan."""
        roster = self.state.get('subagentRoster') or []
        for entry in roster:
            if entry.get('status') in SUBAGENT_LIVE:
                entry.update(status='unknown', endedAt=entry.get('endedAt') or entry.get('updatedAt'), revision=entry.get('revision', 0) + 1)
        folder = ROOT / 'subagents' / self.state['id']
        if not folder.is_dir(): return
        keep = {subagent_filename(x['id']) for x in roster}
        for child in folder.iterdir():
            if child.name in keep: continue
            try: shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
            except OSError: pass
    def subagent_message(self, e):
        message = e.get('message'); parent = e.get('parent_tool_use_id')
        if not isinstance(message, dict) or not isinstance(parent, str): return
        entry = self.subagent_find(parent); created = entry is None
        if created: entry = self.subagent_create(parent, tool_use_id=parent)
        if e.get('type') == 'user' and e.get('isSynthetic'):
            message = copy.deepcopy(message)
            message['content'] = text_parts(message.get('content'))
            for part in message['content']:
                if part.get('type') == 'text': part['source'] = {'kind':'runtime_context','provider':'claude'}
        for part in text_parts(message.get('content')):
            # A nested spawn describes the grandchild its own messages create.
            if isinstance(part, dict) and part.get('type') == 'tool_use' and part.get('name') in SUBAGENT_TOOLS and part.get('id'):
                self.subagent_calls[part['id']] = subagent_call(part.get('input'))
        value = clip_subagent_message(copy.deepcopy(normalize(message, e.get('uuid') or message.get('id') or str(uuid.uuid4()))))
        appended = self.subagent_append(entry, value)
        labelled = appended and any(isinstance(x.get('subagent'), dict) for x in self.state['interactions']) and self.subagent_relabel()
        if created or labelled: self.touch()
    def subagent_main(self, message):
        """Main-thread Agent/Task calls describe the entries their child messages
        create; a call's tool_result ends its entry only when no task event ever
        reported on it, because a background child's result arrives while it runs."""
        changed = False
        for part in text_parts(message.get('content')):
            if not isinstance(part, dict): continue
            if part.get('type') == 'tool_use' and part.get('name') in SUBAGENT_TOOLS and part.get('id'):
                call = self.subagent_calls[part['id']] = subagent_call(part.get('input'))
                entry = self.subagent_find(part['id'])
                if entry and self.subagent_set(entry, **{k:v for k, v in call.items() if entry.get(k) is None}):
                    self.subagent_bump(entry); changed = True
            elif part.get('type') == 'tool_result':
                entry = self.subagent_find(part.get('tool_use_id'))
                if entry and not entry['taskId'] and entry['status'] in SUBAGENT_LIVE:
                    text = clip_chars(tool_result_text(part.get('content')), 600); failed = part.get('is_error') is True
                    self.subagent_set(entry, error=text if failed else None, summary=None if failed else text)
                    self.subagent_finish(entry, 'failed' if failed else 'completed'); changed = True
        if changed: self.subagent_relabel()
    def subagent_task(self, e):
        """Apply one task_* event. None when nothing changed, else whether the entry
        has just finished."""
        kind = e.get('subtype'); task_id = e.get('task_id'); task_type = e.get('task_type')
        tool = e.get('tool_use_id') if isinstance(e.get('tool_use_id'), str) and e.get('tool_use_id') else None
        if not isinstance(task_id, str) or not task_id or task_id in self.subagent_ignored: return None
        # Subagents only: other task kinds, housekeeping and hidden tasks stay out.
        if e.get('ambient') or e.get('skip_transcript') or (task_type and task_type != 'local_agent'):
            self.subagent_ignored.add(task_id); return None
        entry = self.subagent_find(task_id) or self.subagent_find(tool)
        if entry is None:
            if not task_type and tool not in self.subagent_calls:
                if kind == 'task_started': self.subagent_ignored.add(task_id)
                return None
            entry = self.subagent_create(task_id, task_id, tool); changed = True
        else: changed = self.subagent_adopt(entry, task_id, tool)
        live = entry['status'] in SUBAGENT_LIVE; finished = False
        if kind == 'task_notification':
            status = e.get('status') if e.get('status') in ('completed', 'failed', 'stopped') else None
            changed |= self.subagent_set(entry, status=status, summary=clip_chars(e.get('summary'), 600), usage=subagent_usage(e.get('usage')),
                                         endedAt=(entry['endedAt'] or iso_time()) if status else None)
            finished = live and status is not None
        elif not live: pass  # A finished entry never revives from a late event.
        elif kind == 'task_started':
            kind_name = e.get('subagent_type'); background = e.get('is_backgrounded')
            changed |= self.subagent_set(entry, status='running',
                                         description=subagent_call({'description':e.get('description'), 'prompt':e.get('prompt')})['description'],
                                         subagentType=kind_name if isinstance(kind_name, str) and kind_name else None,
                                         background=background if isinstance(background, bool) else None)
        elif kind == 'task_progress':
            kind_name = e.get('subagent_type'); tool_name = e.get('last_tool_name')
            changed |= self.subagent_set(entry, description=clip_chars(e.get('description'), 200),
                                         subagentType=kind_name if isinstance(kind_name, str) and kind_name else None,
                                         usage=subagent_usage(e.get('usage')), summary=clip_chars(e.get('summary'), 600),
                                         lastToolName=tool_name if isinstance(tool_name, str) and tool_name else None)
        else:
            patch = e.get('patch') if isinstance(e.get('patch'), dict) else {}
            status = SUBAGENT_PATCH_STATUS.get(patch.get('status')); ended = patch.get('end_time'); background = patch.get('is_backgrounded')
            finished = status is not None and status not in SUBAGENT_LIVE
            if finished: ended = iso_time(ended / 1000 if ended > 1e11 else ended) if isinstance(ended, (int, float)) and not isinstance(ended, bool) and 0 < ended < 1e14 else iso_time()
            changed |= self.subagent_set(entry, status=status, description=clip_chars(patch.get('description'), 200),
                                         error=clip_chars(patch.get('error'), 600), endedAt=ended if finished else None,
                                         background=background if isinstance(background, bool) else None)
        if not changed: return None
        self.subagent_bump(entry)
        if finished: self.subagent_write(entry['id']); self.subagent_keep(entry)
        self.subagent_relabel()
        return finished
    def subagent_stop_result(self, e):
        entry = self.subagent_find(e.get('taskId'))
        if entry is None or entry['status'] not in SUBAGENT_LIVE: return False
        if e.get('ok') is True:
            if entry['stopError'] is None: return False
            entry['stopError'] = None
        else:
            entry['stopRequested'] = False
            entry['stopError'] = clip_chars(str(e.get('error') or ''), 600) or '停止子 Agent 失败'
        self.subagent_bump(entry)
        return True
    def subagent_settle(self, status=None):
        # The turn is over, so a child its worker never reported on did not end on
        # its own terms: stopped when the turn was cancelled, otherwise unknown.
        status = status or ('stopped' if self.state.get('cancelled') or self.state.get('stopAcknowledged') else 'unknown')
        settled = [x for x in self.state.get('subagentRoster') or [] if x['status'] in SUBAGENT_LIVE]
        for entry in settled: entry['status'] = status; entry['endedAt'] = iso_time(); self.subagent_bump(entry)
        self.subagent_flush()
        for entry in settled: self.subagent_keep(entry)
    def subagent_stop(self, key):
        entry = self.subagent_find(key)
        if entry is None: raise SubagentNotFound('未找到该子 Agent')
        if not self.subagent_view(entry)['canStop']: raise ValueError('该子 Agent 当前无法单独停止')
        if entry['stopRequested']: return
        if entry.get('kind') == 'codex':
            # A v2 child accepts turn/interrupt (unlike turn/start and turn/steer); the
            # child's turn/completed then reports it stopped.
            if not self.codex or self.codex.process.poll() is not None: raise ValueError('Codex app-server 已退出，无法停止子 Agent')
            self.codex.request('turn/interrupt', {'threadId':entry['id'], 'turnId':entry['turnId']})
        else:
            self.send({'type':'stop_task', 'taskId':entry['taskId'], 'turnId':self.state['turnId']})
        entry['stopRequested'] = True; entry['stopError'] = None
        self.subagent_bump(entry); self.touch(True)
    def subagent_page(self, key, epoch=None, revision=None, before=None, limit=None):
        entry = self.subagent_find(key)
        if entry is None: raise SubagentNotFound('未找到该子 Agent')
        transcript = self.subagent_transcript(entry); messages = transcript['messages']; count = len(messages)
        current = epoch == transcript['epoch']
        if before is None and revision is not None and current and int(revision) == entry['revision']: return {'unchanged':True}
        page = {'entry':self.subagent_view(entry), 'epoch':transcript['epoch'], 'revision':entry['revision'],
                'total':count, 'truncated':transcript['truncated']}
        if before is not None:
            if not current: raise ValueError('History changed; reopen the conversation')
            size = int(limit) if limit is not None else 100
            if not 1 <= size <= SUBAGENT_WINDOW: raise ValueError('Invalid history page size')
            end = int(before)
            if not 0 <= end <= count: raise ValueError('Invalid history cursor')
            first = max(0, end - size)
            return page | {'start':first, 'messages':copy.deepcopy(messages[first:end])}
        if revision is not None and current and 0 <= int(revision) < entry['revision']:
            since = int(revision)
            indices = sorted(i for i, version in transcript['versions'].items() if version > since and i < count)
            return page | {'changes':[{'index':i, 'message':copy.deepcopy(messages[i])} for i in indices]}
        first = max(0, count - SUBAGENT_WINDOW)
        return page | {'start':first, 'messages':copy.deepcopy(messages[first:])}

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
        restored.subagent_recover()
        restored.persist()
    # Transcript folders of sessions that no longer exist are orphans.
    folder=ROOT/'subagents'
    if folder.is_dir():
        for child in folder.iterdir():
            if child.name in SESSIONS: continue
            try: shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
            except OSError: pass

class PlanReviewConflict(ValueError):
    pass

class SubagentNotFound(LookupError):
    pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self): self.handle_request(False)
    def do_POST(self): self.handle_request(True)
    def handle_request(self,post):
        if not hmac.compare_digest(self.headers.get('Authorization',''), 'Bearer '+TOKEN): return self.respond(401,{'error':'Unauthorized'})
        try:
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}') if post else {}
            path=urlparse(self.path).path.split('/')
            if urlparse(self.path).path == '/setup' and not post:
                provider = parse_qs(urlparse(self.path).query).get('provider', [''])[0]
                return self.respond(200, setup_status(provider))
            if self.path=='/models' and not post:
                return self.respond(200,{'models':combined_catalog()})
            codex_models=None; selected_home=None; qoder_models=None; qoder_agent=None; qoder_has_model=False
            if post and self.path=='/sessions' and body.get('provider')=='codex':
                selected_home=codex_home()
                codex_models=codex_catalog(selected_home)
            elif post and self.path=='/sessions' and body.get('provider') in QODER_SDK and body.get('model'):
                qoder_agent=body['provider']; qoder_models=qoder_catalog(qoder_agent)
            elif post and len(path)>=4 and path[1]=='sessions' and path[3] in ('model','thinking'):
                with LOCK:
                    target=SESSIONS.get(path[2])
                    target_provider=target.state.get('provider') if target is not None else None
                    needs_codex_catalog=target_provider=='codex'
                    if needs_codex_catalog: selected_home=target.state['codexHome']
                    if target_provider in QODER_SDK:
                        qoder_agent=target_provider
                        qoder_has_model=bool(qoder_requested_model(target.state))
                if needs_codex_catalog: codex_models=codex_catalog(selected_home)
                if qoder_agent and (body.get('model') or (path[3]=='thinking' and qoder_has_model)): qoder_models=qoder_catalog(qoder_agent)
            elif not post and len(path)==5 and path[1]=='sessions' and path[3]=='subagents':
                # A Codex child's own history is read from the runtime outside the lock.
                with LOCK:
                    target=SESSIONS.get(path[2])
                    backfill=target.subagent_guard(target.codex_backfill_plan,unquote(path[4])) if target is not None else None
                if backfill: target.codex_backfill(backfill)
            with LOCK:
                if self.path=='/health':
                    result={'version':SERVICE_VERSION,'implementation':SOURCE_FINGERPRINT,'startedAt':STARTED_AT,'pid':os.getpid()}
                    if os.environ.get('PERCH_LOCAL_CODEX'):
                        result['localCodexBinary']=str(pathlib.Path(os.environ['PERCH_LOCAL_CODEX']).resolve())
                elif self.path=='/sessions' and not post: result={'sessions':[s.summary() for s in SESSIONS.values()]}
                elif self.path=='/sessions' and post:
                    provider=body.get('provider')
                    if provider not in PERMISSION_MODES or not os.path.isabs(body.get('cwd','')) or not os.path.isdir(body['cwd']): raise ValueError('请选择有效的远端绝对目录')
                    mode=permission_mode(provider,body.get('permissionMode'))
                    model=body.get('model',''); thinking=body.get('thinking'); qoder_entry=None
                    if provider=='codex':
                        codex_permission_params(mode)
                        _,thinking=codex_selection(model,thinking,codex_models)
                    elif provider in QODER_SDK:
                        qoder_entry,thinking=qoder_selection(provider,model,thinking,qoder_models)
                    sid=str(uuid.uuid4()); s=Session({'id':sid,'provider':provider,'title':body.get('title') or '新对话','cwd':body['cwd'],'model':model,'thinking':thinking,'permissionMode':mode,'busy':False,'archived':False,'updated':time.time(),'revision':0,'completed':0,'messages':[],'interactions':[],'error':None})
                    if provider in QODER_SDK: apply_qoder_selection(s.state,qoder_entry,thinking)
                    SESSIONS[sid]=s
                    if body['provider']=='codex':
                        s.state['codexHome']=selected_home
                        try: s.codex_start_thread()
                        except Exception:
                            s.deleted=True
                            if s.codex and s.state.get('resume'):
                                try: s.codex.request('thread/delete',{'threadId':s.state['resume']})
                                except Exception: pass
                            if s.codex: s.codex.close()
                            for key,value in list(SESSIONS.items()):
                                if value is s: del SESSIONS[key]
                            if s.path.exists(): s.path.unlink()
                            raise
                    else:
                        s.persist()
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
                    elif not post and len(path)==5 and path[3]=='subagents':
                        query=parse_qs(urlparse(self.path).query)
                        result=s.subagent_page(unquote(path[4]),**{k:query[k][0] for k in ('epoch','revision','before','limit') if k in query})
                    elif not post:
                        query=parse_qs(urlparse(self.path).query)
                        result=s.snapshot(**{k:query[k][0] for k in ('revision','turns','start','epoch','before') if k in query})
                    else:
                        action=path[3]
                        if action=='subagents' and len(path)==6 and path[5]=='stop':
                            s.subagent_stop(unquote(path[4]))
                        elif action=='prompt':
                            result=s.prompt(body)
                        elif action=='steer':
                            result=s.steer(body)
                        elif action=='model':
                            if s.state['provider'] not in ('omp','qoder','qoderintl','dsh','codex'): raise ValueError('当前 Agent 不支持切换模型')
                            if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                            provider,model=body.get('provider',''),body.get('model','')
                            if s.state['provider'] in QODER_SDK:
                                entry,selected=qoder_selection(s.state['provider'],model,catalog=qoder_models)
                                current=s.state.get('thinking')
                                if entry is not None and current in entry.get('thinking',[]): selected=current
                                apply_qoder_selection(s.state,entry,selected); s.touch(True)
                            elif not provider or not model: raise ValueError('请同时指定 provider 和模型')
                            elif s.state['provider']=='codex':
                                if provider!='codex': raise ValueError('Codex 不认识该模型，请刷新模型列表后重试')
                                entry,_=codex_selection(model,catalog=codex_models)
                                s.state['model']=model; s.state['context']=None
                                if s.state.get('thinking') not in entry.get('thinking',[]): s.state['thinking']=entry.get('defaultThinking')
                                s.touch(True)
                            elif s.state['provider']=='dsh':
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
                        elif action=='permission':
                            if s.state['provider'] not in ('qoder','qoderintl','claude'): raise ValueError('当前 Agent 的权限在创建会话时固定')
                            mode=permission_mode(s.state['provider'],body.get('mode'))
                            s.state['permissionMode']=mode; s.touch(True)
                            result={'ok':True,'permission':permission_capability(s.state)}
                        elif action=='thinking':
                            if s.state['provider'] not in ('omp','qoder','qoderintl','dsh','codex'): raise ValueError('当前 Agent 不支持设置思考强度')
                            level=body.get('level','')
                            if not level: raise ValueError('请指定思考强度')
                            if s.state['provider'] in QODER_SDK:
                                if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                                qoder_selection(s.state['provider'],qoder_requested_model(s.state),level,qoder_models)
                                s.state['thinking']=level; s.touch(True)
                            elif s.state['provider']=='codex':
                                if s.state['busy']: raise ValueError('请先停止或完成当前任务')
                                codex_selection(s.state.get('model'),level,codex_models)
                                s.state['thinking']=level; s.touch(True)
                            elif s.state['provider']=='dsh':
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
                                if s.state['provider']=='codex':
                                    s.codex_ensure(True).request('turn/interrupt',{'threadId':s.state['resume'],'turnId':body['turnId']})
                                elif s.state['provider']=='dsh':
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
                            if 'planRevision' in body:
                                s.answer_plan(body)
                            else:
                                item=next(x for x in s.snapshot()['interactions'] if x['id']==body['id'])
                                if item.get('planReview'): raise PlanReviewConflict('请更新客户端并查看计划后审批')
                                if s.state['provider']=='codex':
                                    s.codex_answer(body['id'],body)
                                elif s.state['provider']=='omp':
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
                                if s.state['provider']!='codex':
                                    s.state['interactions']=[x for x in s.state['interactions'] if x['id']!=body['id']]; s.touch(True)
                        elif action=='archive':
                            if s.state['busy']: raise ValueError('请先停止或完成任务')
                            if s.state['provider']=='codex':
                                method='thread/archive' if body['archived'] else 'thread/unarchive'
                                s.codex_ensure(False).request(method,{'threadId':s.state['resume']})
                            s.state['archived']=body['archived']; s.touch(True)
                        elif action=='delete':
                            if s.state['busy']: raise ValueError('请先停止或完成任务')
                            if s.state['provider']=='codex':
                                s.codex_ensure(False).request('thread/delete',{'threadId':s.state['resume']})
                            s.deleted = True
                            if s.codex: s.codex.close()
                            if s.process and s.process.poll() is None: s.process.stdin.close()
                            s.path.unlink(missing_ok=True); del SESSIONS[s.state['id']]
                            shutil.rmtree(ROOT/'attachments'/s.state['id'], ignore_errors=True)
                            s.subagent_discard()
                        else: raise ValueError('未知操作')
                        if action not in ('prompt','steer','permission'): result={'ok':True}
                else: raise ValueError('未知路径')
            self.respond(200,result)
        except PlanReviewConflict as e: self.respond(409,{'error':str(e)})
        except SubagentNotFound as e: self.respond(404,{'error':str(e)})
        except Exception as e: self.respond(400,{'error':str(e)})
    def respond(self,status,body):
        data=json.dumps(body,ensure_ascii=False).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)

def endpoint_request(endpoint, path, timeout=2):
    request=urllib.request.Request('http://127.0.0.1:'+str(endpoint['port'])+path,
        headers={'Authorization':'Bearer '+endpoint['token']})
    return json.loads(urllib.request.urlopen(request,timeout=timeout).read())

def running_endpoint(path):
    if not path.exists(): return None, None
    try:
        endpoint=json.loads(path.read_text())
        return endpoint, endpoint_request(endpoint,'/health')
    except Exception: return None, None

def active_session(session):
    # A summary reports running subagents as a count, a snapshot as its live list.
    command=session.get('commandResult'); subagents=session.get('subagents')
    return bool(session.get('busy') or session.get('pending') or session.get('runningSubagents') or
        isinstance(subagents,list) and any(isinstance(x,dict) and x.get('status') in SUBAGENT_LIVE for x in subagents) or
        session.get('turnState') in ('submitting','submitted','accepted','running') or
        isinstance(command,dict) and command.get('status')=='running')

def serves_current_code(health):
    """A running service counts as current only when it reports this protocol, the
    selected local Codex binary and this exact source. A service too old to report
    its source is not assumed to match. When the local file cannot be read the
    version alone decides, so an unreadable digest never restarts a healthy
    service on every check."""
    if health.get('version')!=SERVICE_VERSION: return False
    local_binary=os.environ.get('PERCH_LOCAL_CODEX')
    if local_binary and health.get('localCodexBinary')!=str(pathlib.Path(local_binary).resolve()): return False
    if not SOURCE_FINGERPRINT: return True
    return health.get('implementation')==SOURCE_FINGERPRINT

def reusable_endpoint(path):
    endpoint,health=running_endpoint(path)
    if endpoint is None: return None
    if serves_current_code(health): return endpoint
    try:
        catalog=endpoint_request(endpoint,'/sessions')
        sessions=catalog.get('sessions')
        if not isinstance(sessions,list): raise ValueError('invalid session catalog')
    except Exception:
        return endpoint | {'restartPending':-1}
    active=sum(1 for session in sessions if active_session(session))
    if active: return endpoint | {'restartPending':active}
    try:
        snapshots=[]
        for session in sessions:
            identity=session.get('id')
            if not isinstance(identity,str) or not identity: raise ValueError('invalid session identity')
            snapshots.append(endpoint_request(endpoint,'/sessions/'+identity))
    except Exception:
        return endpoint | {'restartPending':-1}
    active=sum(1 for session in snapshots if active_session(session))
    if active: return endpoint | {'restartPending':active}
    pid=endpoint.get('pid')
    if type(pid) is not int or pid<=1 or pid==os.getpid(): return endpoint | {'restartPending':-1}
    try: os.kill(pid,signal.SIGTERM)
    except ProcessLookupError: pass
    except OSError: return endpoint | {'restartPending':-1}
    else:
        for _ in range(50):
            time.sleep(.1)
            try: endpoint_request(endpoint,'/health',timeout=1)
            except Exception: break
        else: return endpoint | {'restartPending':-1}
    return None

def ensure_service():
    endpoint_path=ROOT/'endpoint.json'
    endpoint=reusable_endpoint(endpoint_path)
    if endpoint is not None: return endpoint
    with warnings.catch_warnings():
        warnings.simplefilter('ignore',ResourceWarning)
        with open(ROOT/'service.log','a') as log:
            process=subprocess.Popen([sys.executable,__file__],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        del process
    for _ in range(100):
        time.sleep(.1)
        endpoint,health=running_endpoint(endpoint_path)
        if endpoint is not None and serves_current_code(health): return endpoint
    raise SystemExit('托管服务未启动')

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--ensure',action='store_true'); args=parser.parse_args()
    if args.ensure:
        print(json.dumps(ensure_service())); sys.exit(0)
    lockfile=open(ROOT/'service.lock','w'); fcntl.flock(lockfile,fcntl.LOCK_EX|fcntl.LOCK_NB)
    TOKEN=secrets.token_urlsafe(32); load()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    save(ROOT/'endpoint.json',{'port':server.server_port,'token':TOKEN,'pid':os.getpid()})
    server.serve_forever()
