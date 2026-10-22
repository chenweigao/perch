#!/usr/bin/env python3
"""Generate the Windows client's fixtures from the real bridge code.

Nothing here talks to a model, a network or a real Codex CLI. It imports
remote/native-agent-service.py the way remote/test_native_service.py does, replaces
only the Codex app-server with an in-process fake, and writes the JSON the bridge's
own summary()/snapshot()/prompt() produce for every route the Windows client calls.

Re-run after changing the bridge or the client's route set:

    python3 windows/tools/generate-fixtures.py
"""
import importlib.util, itertools, json, pathlib, sys, tempfile, uuid
from unittest.mock import patch

REPO = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(__file__).resolve().parents[1] / 'tests' / 'Perch.Core.Tests' / 'fixtures'
THREAD = 'native-thread-1'

# Fixtures must be byte-reproducible so CI can fail when the committed ones drift from
# the current bridge. Two values the bridge derives at runtime would otherwise differ on
# every run: history `epoch` (uuid4) and message `created_at` (time.time). Freeze both;
# the source fingerprint in health.json stays real, so a bridge edit still shows up.
FROZEN_TIME = 1760000000.0
_uuid_counter = itertools.count(0x1000)


def deterministic_uuid4():
    return uuid.UUID(int=next(_uuid_counter))


def frozen_time():
    return FROZEN_TIME


def load_broker(root):
    spec = importlib.util.spec_from_file_location('broker', REPO / 'remote' / 'native-agent-service.py')
    broker = importlib.util.module_from_spec(spec)
    with patch.dict('os.environ', {'AWB_NATIVE_ROOT': root}):
        spec.loader.exec_module(broker)
    return broker


class FakeCodex:
    """Stands in for CodexAppServer: records calls, replays frames on demand."""

    def __init__(self, *args, **kwargs):
        self.calls = []
        self.responses = []
        self.closed = False
        owner = self
        self.process = type('Process', (), {'poll': lambda _s: 0 if owner.closed else None})()
        self.results = {
            'thread/start': {'thread': {'id': THREAD, 'model': 'gpt-5-codex', 'reasoningEffort': 'medium'}},
            'thread/resume': {'thread': {'id': THREAD, 'model': 'gpt-5-codex', 'reasoningEffort': 'medium'}},
            'thread/items/list': {'data': [], 'nextCursor': None},
            'turn/start': {'turn': {'id': 'turn-1', 'status': 'inProgress'}},
            'turn/interrupt': {},
            'account/read': {'requiresOpenaiAuth': False},
            'model/list': {'data': [{'id': 'gpt-5-codex', 'model': 'gpt-5-codex', 'displayName': 'GPT-5 Codex',
                                     'defaultReasoningEffort': 'medium',
                                     'supportedReasoningEfforts': [{'reasoningEffort': 'low'},
                                                                   {'reasoningEffort': 'medium'}]},
                                    {'id': 'gpt-5', 'model': 'gpt-5', 'displayName': 'GPT-5',
                                     'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}],
                           'nextCursor': None},
        }
        self.on_frame = None
        self.on_exit = None

    def initialize(self):
        self.calls.append(('initialize', {}))

    def request(self, method, params, timeout=60):
        self.calls.append((method, params))
        result = self.results.get(method, {})
        return result.pop(0) if isinstance(result, list) else result

    def respond(self, request_id, result=None, error=None):
        self.responses.append((request_id, result, error))

    def notify(self, method, params):
        self.calls.append((method, params))

    def close(self):
        self.closed = True


def session_state(session_id, title, cwd='/home/developer/项目 目录', updated=1760000000.0):
    return {
        'id': session_id, 'provider': 'codex', 'title': title, 'cwd': cwd, 'model': 'gpt-5-codex',
        'thinking': 'medium', 'permissionMode': 'workspace-ask', 'busy': False, 'archived': False,
        'updated': updated, 'revision': 0, 'completed': 0, 'messages': [], 'interactions': [],
        'error': None, 'codexHome': '/home/developer/.codex',
    }


def codex_session(broker, session_id, title, cwd='/home/developer/项目 目录', updated=1760000000.0):
    """A real bridge Session with a fake Codex already attached.

    codex_ensure() normally wires on_frame; this reproduces that one line so replayed
    frames travel through the bridge's real handler.
    """
    session = broker.Session(session_state(session_id, title, cwd, updated))
    fake = FakeCodex()
    session.codex = fake
    session.codex_attached = True
    session.state['resume'] = THREAD
    fake.on_frame = lambda frame: session.codex_frame(fake, frame)
    return session, fake


def agent_delta(codex, text, item='item-1'):
    codex.on_frame({'jsonrpc': '2.0', 'method': 'item/agentMessage/delta',
                    'params': {'threadId': THREAD, 'itemId': item, 'delta': text}})


def write(name, value):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('wrote %s (%d bytes)' % (path.relative_to(REPO), path.stat().st_size))


def main():
    folder = tempfile.TemporaryDirectory()
    broker = load_broker(folder.name)

    write('health.json', {'version': broker.SERVICE_VERSION, 'implementation': broker.SOURCE_FINGERPRINT,
                          'startedAt': '2026-10-21T09:14:00+08:00', 'pid': 4242})
    write('endpoint.json', {'port': 41873, 'token': 'fixture-token-do-not-use', 'pid': 4242})

    # Freeze the two runtime-derived values so fixtures are byte-reproducible. Everything
    # else (message text, tool shapes, indices, digests) is the bridge's real output.
    with patch.object(broker, 'SESSIONS', {}), \
            patch.object(broker.time, 'time', frozen_time), \
            patch.object(broker.uuid, 'uuid4', deterministic_uuid4):
        # A running Codex turn whose reply streams in as deltas.
        busy, busy_codex = codex_session(broker, 'ses-busy', '重构登录页 "引号" & emoji 🚀',
                                         updated=1760000300.0)
        busy.state.update(busy=True, turnId='turn-1', turnState='running')
        busy.upsert({'role': 'user',
                     'content': '请修复 C:\\Users\\me\\项目 & 测试 \'quoted\' 的路径；执行 `ls $HOME` && echo "ok"'},
                    'req-1')
        busy.touch(True)
        agent_delta(busy_codex, '正在处理 ')
        agent_delta(busy_codex, '中文 🚀')

        # A turn waiting on a command approval.
        approval, _ = codex_session(broker, 'ses-approval', '等待审批的会话', '/home/developer/repo')
        approval.codex_interactions['codex-request-7'] = {
            'wireId': 7, 'method': 'item/commandExecution/requestApproval',
            'params': {'command': ['rm', '-rf', '/tmp/项目 x'], 'cwd': '/home/developer/repo', 'reason': '需要执行命令'},
        }
        approval.state['interactions'].append({
            'id': 'codex-request-7', 'type': 'interaction', 'name': 'shell', 'title': 'Codex 请求确认',
            'input': {'command': 'rm -rf /tmp/项目 x', 'cwd': '/home/developer/repo', 'reason': '需要执行命令'},
        })
        approval.state.update(busy=True, turnId='turn-9', turnState='running')

        idle, _ = codex_session(broker, 'ses-idle', '空闲会话', '/home/developer/other repo')
        idle.state['completed'] = 3
        idle.upsert({'role': 'user', 'content': '你好'}, 'req-old')
        idle.upsert({'role': 'assistant', 'content': [{'type': 'text', 'text': '你好，已完成。'}]}, 'codex:item-9')
        idle.touch(True)

        for session in (busy, approval, idle):
            broker.SESSIONS[session.state['id']] = session

        write('sessions.json', {'sessions': [s.summary() for s in broker.SESSIONS.values()]})

        write('session-snapshot-full.json', busy.snapshot())
        write('session-snapshot-unchanged.json', busy.snapshot(revision=str(busy.state['revision'])))

        # The Mac client's first read of a selection is paged; only a paged snapshot
        # carries the history window that later delta reads are keyed on.
        paged = busy.snapshot(turns='25')
        write('session-snapshot-paged.json', paged)
        window = paged['history']

        base_revision = busy.state['revision']
        agent_delta(busy_codex, ' 完成 ✅')
        write('session-snapshot-delta.json', busy.snapshot(revision=str(base_revision),
                                                           start=str(window['start']), epoch=window['epoch']))
        # The same revision answers "unchanged": this is what stops a poll from
        # rebuilding the transcript.
        write('session-snapshot-delta-unchanged.json',
              busy.snapshot(revision=str(busy.state['revision']),
                            start=str(window['start']), epoch=window['epoch']))

        # A delta that edits the streaming message and appends a completed tool call.
        base_revision = busy.state['revision']
        window = busy.snapshot(turns='25')['history']
        busy_codex.on_frame({'jsonrpc': '2.0', 'method': 'item/completed', 'params': {
            'threadId': THREAD, 'completedAtMs': 1760000099000,
            'item': {'type': 'commandExecution', 'id': 'item-2', 'command': 'ls "/home/developer/项目 目录"',
                     'aggregatedOutput': '文件 1\n文件 2\n', 'status': 'completed', 'exitCode': 0}}})
        write('session-snapshot-delta-append.json', busy.snapshot(revision=str(base_revision),
                                                                  start=str(window['start']),
                                                                  epoch=window['epoch']))

        # A stale epoch: what the bridge answers once history has been replaced. The
        # client treats this 400 as "force a full re-read", never as a merge.
        write('error-stale-epoch.json', {'status': 400, 'body': {'error': 'History changed; reopen the conversation'}})

        write('request-receipt-notfound.json', {'id': 'req-missing', 'status': 'notFound'})

        # A real prompt round trip, with shell metacharacters and Chinese in the text.
        prompt_session, prompt_codex = codex_session(broker, 'ses-prompt', '发送测试', '/home/developer/repo')
        prompt_text = 'shell 元字符 $VAR `whoami` && rm -rf / "引号" \'single\' 中文 🚀 C:\\路径 空格'
        write('prompt-receipt.json', prompt_session.prompt({'requestId': 'req-send-1', 'text': prompt_text}))
        # What the bridge handed Codex: the text rides as a structured `input` text item,
        # never a shell string. This is the end-to-end proof that a prompt cannot inject.
        turn_start = [c for c in prompt_codex.calls if c[0] == 'turn/start']
        write('prompt-turn-start-params.json', turn_start[-1][1] if turn_start else {})
        # Re-sending the same requestId is idempotent; different text is refused.
        write('prompt-receipt-replay.json', prompt_session.prompt({'requestId': 'req-send-1', 'text': prompt_text}))

        write('session-snapshot-approval.json', approval.snapshot())
        write('session-snapshot-idle.json', idle.snapshot())

    write('error-unauthorized.json', {'status': 401, 'body': {'error': 'Unauthorized'}})
    write('error-bad-request.json', {'status': 400, 'body': {'error': '轮次已变化，请重新同步'}})
    folder.cleanup()
    return 0


if __name__ == '__main__':
    sys.exit(main())
