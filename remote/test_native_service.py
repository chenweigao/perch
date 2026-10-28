import importlib.util, base64, io, json, os, pathlib, shutil, subprocess, sys, tempfile, threading, time, unittest
from unittest.mock import patch

def setUpModule():
    # Discovery imports all modules before running them. Create this module's
    # runtime only when its tests start, not in another module's cleanup scope.
    global folder, broker
    folder=tempfile.TemporaryDirectory()
    spec=importlib.util.spec_from_file_location('broker',pathlib.Path(__file__).with_name('native-agent-service.py'))
    broker=importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, {'AWB_NATIVE_ROOT':folder.name}):
        spec.loader.exec_module(broker)

def tearDownModule():
    folder.cleanup()

class ProxySpawnEnvironmentTests(unittest.TestCase):
    def test_local_symlinked_codex_can_find_bundled_tool_helpers(self):
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            bundle = root/'App Resources'; bundle.mkdir()
            binary = bundle/'codex'; binary.touch()
            link = root/'codex'; link.symlink_to(binary)
            with patch.dict(os.environ, {'PERCH_LOCAL_CODEX':str(link)}), \
                 patch.object(broker, 'proxy_aware_spawn_env', return_value={'PATH':'/usr/bin'}), \
                 patch.object(broker.subprocess, 'Popen') as launch, \
                 patch.object(broker.threading.Thread, 'start'):
                broker.CodexAppServer(str(root))
                self.assertEqual(launch.call_args.args[0][0], str(binary.resolve()))
                self.assertEqual(launch.call_args.kwargs['env']['PATH'], str(bundle.resolve()) + os.pathsep + '/usr/bin')

    def test_preserves_existing_proxy_variants_without_probing(self):
        for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
            with self.subTest(key=key), patch.dict(os.environ, {key:'http://existing-proxy:8080'}, clear=True), \
                 patch.object(broker.urllib.request, 'urlopen') as probe:
                self.assertEqual(broker.proxy_aware_spawn_env(), {key:'http://existing-proxy:8080'})
                probe.assert_not_called()

    def test_loads_proxy_file_when_parent_has_no_proxy(self):
        content = 'export https_proxy=http://127.0.0.1:7890\nexport no_proxy="localhost,127.0.0.1"\nexport NO_PROXY="$no_proxy"'
        with patch.dict(os.environ, {'PATH':'/usr/bin'}, clear=True), \
             patch.object(broker.urllib.request, 'urlopen') as probe, \
             patch.object(pathlib.Path, 'read_text', return_value=content):
            self.assertEqual(broker.proxy_aware_spawn_env(), {'PATH':'/usr/bin', 'https_proxy':'http://127.0.0.1:7890',
                                                       'no_proxy':'localhost,127.0.0.1', 'NO_PROXY':'localhost,127.0.0.1'})
            probe.assert_called_once_with('http://127.0.0.1:9090/version', timeout=1)

class QoderWorkerTests(unittest.TestCase):
    def run_worker(self, sdk, config, prompt=None, env=None):
        node = shutil.which('node')
        if not node: self.skipTest('node is not installed')
        worker = pathlib.Path(__file__).with_name('qoder-worker.mjs')
        result = subprocess.run([node, str(worker), json.dumps({'sdk':str(sdk), **config})],
                                input=(json.dumps(prompt) + '\n') if prompt else None,
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]

    def test_catalog_uses_daemon_live_models_without_creating_query(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory); sdk = directory/'fake-sdk.mjs'; log = directory/'calls.jsonl'
            sdk.write_text("""import {appendFileSync} from 'node:fs';
const record = value => appendFileSync(process.env.QODER_FAKE_LOG, JSON.stringify(value) + '\\n');
export const qodercliAuth = () => ({fixture:true});
export async function startDaemon(options) {
  record({call:'startDaemon', options});
  return {
    async getModels(options) { record({call:'getModels', options}); return [{value:'qoder-pro'}]; },
    async stop() { record({call:'stop'}); }
  };
}
export function query() { record({call:'query'}); throw new Error('catalog must not create a query'); }
""")
            env = dict(os.environ, QODER_FAKE_LOG=str(log))
            lines = self.run_worker(sdk, {'operation':'catalog', 'cwd':str(directory), 'binary':'/fixture/qoder'}, env=env)
            self.assertEqual(lines, [{'type':'models', 'models':[{'value':'qoder-pro'}]}])
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([item['call'] for item in calls], ['startDaemon','getModels','stop'])
            self.assertEqual(calls[1]['options'], {'fetchStrategy':'live'})
            self.assertEqual(calls[0]['options']['pathToQoderCLIExecutable'], '/fixture/qoder')

    def test_selected_model_only_overrides_main_and_plan_purposes(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory); sdk = directory/'fake-sdk.mjs'
            sdk.write_text("""export const qodercliAuth = () => ({fixture:true});
export function query({prompt, options}) {
  const purposes = ['main','plan','title','compact','subagent','compression','utility'];
  const resolved = Object.fromEntries(purposes.map(purpose => [purpose, options.resolveModel?.({purpose}) ?? null]));
  return {async interrupt() {}, async *[Symbol.asyncIterator]() {
    yield {type:'capture', prompt, topModel:options.model ?? null, resolved};
  }};
}
""")
            command = {'type':'prompt', 'id':'turn-1', 'message':'work', 'model':'qoder-pro', 'thinking':'high',
                       'outerProvider':'alibaba', 'contextWindow':131072}
            lines = self.run_worker(sdk, {'cwd':str(directory), 'binary':'/fixture/qoder'}, command)
            capture = next(item for item in lines if item.get('type') == 'capture')
            selected = {'model':'qoder-pro', 'parameters':{'contextWindow':131072,
                        'reasoningEffort':'high', 'outerProvider':'alibaba'}}
            self.assertEqual(capture['topModel'], 'qoder-pro')
            self.assertEqual(capture['resolved']['main'], selected)
            self.assertEqual(capture['resolved']['plan'], selected)
            for purpose in ('title','compact','subagent','compression','utility'):
                self.assertIsNone(capture['resolved'][purpose])

            default_lines = self.run_worker(sdk, {'cwd':str(directory), 'binary':'/fixture/qoder', 'model':'stale'},
                                            {'type':'prompt', 'id':'turn-2', 'message':'default', 'model':''})
            default_capture = next(item for item in default_lines if item.get('type') == 'capture')
            self.assertIsNone(default_capture['topModel'])
            self.assertTrue(all(value is None for value in default_capture['resolved'].values()))

class QoderCatalogTests(unittest.TestCase):
    def result(self, payload, code=0, stderr=''):
        return type('Result', (), {'returncode':code, 'stdout':json.dumps(payload), 'stderr':stderr})()

    def test_catalog_normalizes_sdk_models_and_keeps_routing_private(self):
        raw = [{'value':'qoder-pro','displayName':'Qoder Pro','provider':'catalog-vendor',
                'outerProvider':'trusted-route','maxInputTokens':131072,
                'efforts':['low','high','low',None],'defaultEffort':'high',
                'isReasoning':True,'isDefault':True},
               {'value':'disabled','isEnabled':False},
               {'modelId':'qoder-lite','agent':'agent-vendor','efforts':[],
                'defaultEffort':'unsupported','isDefault':False},
               {'displayName':'missing id'}]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            package = root/'node_modules'/'@qodercn-ai'/'qodercn-agent-sdk'/'package.json'
            package.parent.mkdir(parents=True); package.write_text('{}')
            def which(binary):
                return {'node':'/fixture/node','qoderclicn':'/fixture/qoderclicn'}.get(binary)
            output = self.result({'type':'models','models':raw})
            with patch.object(broker,'ROOT',root), patch.object(broker,'QODER_MODELS',{}), \
                 patch.object(broker.shutil,'which',side_effect=which), \
                 patch.object(broker.subprocess,'run',return_value=output) as run:
                models = broker.qoder_catalog('qoder')
                self.assertIs(models, broker.qoder_catalog('qoder'))
            self.assertEqual(run.call_count, 1)
        self.assertEqual(models, [
            {'id':'qoder-pro','provider':'catalog-vendor','name':'Qoder Pro',
             'thinking':['low','high'],'isDefault':True,'contextWindow':131072,
             'reasoning':True,'defaultThinking':'high','_outerProvider':'trusted-route'},
            {'id':'qoder-lite','provider':'agent-vendor','name':'qoder-lite',
             'thinking':[],'isDefault':False}])
        public = broker.qoder_public_model(models[0])
        self.assertNotIn('_outerProvider', public)
        self.assertNotIn('trusted-route', json.dumps(broker.catalog_entries(models,'qoder')))

    def test_cn_and_international_catalogs_use_their_own_sdk_and_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); calls = []
            for sdk in broker.QODER_SDK.values():
                package = root/'node_modules'/sdk/'package.json'; package.parent.mkdir(parents=True,exist_ok=True); package.write_text('{}')
            def which(binary): return '/fixture/' + binary
            def run(command, **kwargs):
                cfg = json.loads(command[-1]); calls.append((command,cfg,kwargs))
                return self.result({'type':'models','models':[{'value':cfg['sdk']} ]})
            with patch.object(broker,'ROOT',root), patch.object(broker,'QODER_MODELS',{}), \
                 patch.object(broker.shutil,'which',side_effect=which), \
                 patch.object(broker.subprocess,'run',side_effect=run):
                cn = broker.qoder_catalog('qoder'); international = broker.qoder_catalog('qoderintl')
            self.assertEqual(cn[0]['id'], '@qodercn-ai/qodercn-agent-sdk')
            self.assertEqual(international[0]['id'], '@qoder-ai/qoder-agent-sdk')
            self.assertEqual([cfg['binary'] for _,cfg,_ in calls], ['/fixture/qoderclicn','/fixture/qodercli'])
            self.assertEqual([cfg['sdk'] for _,cfg,_ in calls],
                             ['@qodercn-ai/qodercn-agent-sdk','@qoder-ai/qoder-agent-sdk'])
            self.assertTrue(all(cfg['operation'] == 'catalog' for _,cfg,_ in calls))
            self.assertTrue(all(kwargs['timeout'] == 60 for _,_,kwargs in calls))

    def test_selection_accepts_runtime_default_and_validates_effort(self):
        catalog = [{'id':'pro','provider':'vendor','thinking':['low','high'],
                    'defaultThinking':'high','_outerProvider':'route','contextWindow':1000}]
        self.assertEqual(broker.qoder_selection('qoder','',catalog=catalog),(None,None))
        with self.assertRaisesRegex(ValueError,'默认模型'):
            broker.qoder_selection('qoder','',thinking='high',catalog=catalog)
        with self.assertRaisesRegex(ValueError,'不认识'):
            broker.qoder_selection('qoder','unknown',catalog=catalog)
        with self.assertRaisesRegex(ValueError,'不支持'):
            broker.qoder_selection('qoder','pro',thinking='max',catalog=catalog)
        entry, effort = broker.qoder_selection('qoder','pro',catalog=catalog)
        state = {'model':'','thinking':None}; broker.apply_qoder_selection(state,entry,effort)
        self.assertEqual((state['model'],state['qoderRequestedModel'],state['thinking'],state['provider_id']),('pro','pro','high','vendor'))
        self.assertEqual((state['qoderOuterProvider'],state['qoderContextWindow']),('route',1000))
        broker.apply_qoder_selection(state,None,None)
        self.assertEqual(state,{'model':'','qoderRequestedModel':'','thinking':None})

class ProtocolTests(unittest.TestCase):
    def session(self, provider='omp'):
        return broker.Session({'id':'qa','provider':provider,'cwd':'/tmp','title':'QA','model':'','busy':False,'archived':False,'updated':0,'revision':0,'completed':0,'messages':[],'interactions':[],'error':None})
    def test_omp_stream_and_final_are_one_message(self):
        s=self.session()
        for text in ['中','中文']:
            s.event({'type':'message_update','message':{'role':'assistant','timestamp':42,'content':[{'type':'text','text':text}]}})
        s.event({'type':'message_end','message':{'role':'assistant','timestamp':42,'content':[{'type':'text','text':'中文完成'}]}})
        self.assertEqual(len(s.state['messages']),1)
        self.assertEqual(s.state['messages'][0]['content'][0]['text'],'中文完成')
    def test_state_excludes_credentials(self):
        s=self.session();s.event({'type':'response','command':'get_state','success':True,'data':{'sessionFile':'/tmp/qa.jsonl','model':{'id':'test','headers':{'Authorization':'secret'}}}})
        self.assertNotIn('secret',json.dumps(s.state));self.assertEqual(s.state['resume'],'/tmp/qa.jsonl')
    def test_approval_wait_survives_snapshot_and_expiry(self):
        s=self.session();s.event({'type':'extension_ui_request','id':'approval','method':'select','title':'Tool','options':['Approve','Deny']})
        self.assertEqual(s.snapshot()['interactions'][0]['id'],'approval')
        saved=json.loads(s.path.read_text());self.assertEqual(saved['interactions'][0]['id'],'approval')
        s.state['interactions'][0]['expires']=1
        self.assertEqual(s.snapshot()['interactions'],[])
    def test_cancelled_and_failed_turns_do_not_enter_review(self):
        for field,value in [('cancelled',True),('error','failure')]:
            s=self.session();s.state[field]=value;s.state['busy']=True
            s.event({'type':'agent_end'});self.assertEqual(s.state['completed'],0);self.assertFalse(s.state['busy'])
        s=self.session();s.event({'type':'agent_end','isTerminal':False});self.assertEqual(s.state['completed'],0)
        s.event({'type':'agent_end'});self.assertEqual(s.state['completed'],1)
    def test_qoder_interrupt_is_not_an_error(self):
        s=self.session('qoder');s.state['cancelled']=True
        s.event({'type':'result','is_error':True,'errors':['Operation aborted']})
        s.event({'type':'worker_error','message':'Operation aborted'})
        s.event({'type':'agent_end'});self.assertIsNone(s.state['error']);self.assertEqual(s.state['completed'],0)
    def test_model_thinking_and_context_come_from_runtime_state(self):
        s=self.session()
        s.event({'type':'response','command':'get_state','success':True,'data':{
            'sessionFile':'/tmp/qa.jsonl','thinkingLevel':'high',
            'model':{'id':'gpt-5.4-mini','provider':'openai-codex'},
            'contextUsage':{'tokens':17848,'contextWindow':272000,'percent':6.56}}})
        self.assertEqual(s.state['model'],'gpt-5.4-mini')
        self.assertEqual(s.state['provider_id'],'openai-codex')
        self.assertEqual(s.state['thinking'],'high')
        self.assertEqual(s.state['context'],{'tokens':17848,'limit':272000})
        self.assertEqual(s.summary()['context'],{'tokens':17848,'limit':272000})
        self.assertEqual(s.summary()['thinking'],'high')
        # A runtime that reports no window leaves context absent so the client can
        # show "unknown" instead of a full bar.
        s.event({'type':'response','command':'get_state','success':True,'data':{'model':{'id':'x'},'contextUsage':{}}})
        self.assertIsNone(s.state['context'])
    def test_omp_model_switch_requires_idle_and_both_fields(self):
        s=self.session()
        s.state['busy']=True
        with self.assertRaises(ValueError): self.apply_model(s,{'provider':'openai-codex','model':'gpt-5.4-mini'})
        s.state['busy']=False
        with self.assertRaises(ValueError): self.apply_model(s,{'model':'gpt-5.4-mini'})
        with self.assertRaises(ValueError): self.apply_model(s,{'provider':'openai-codex'})
        self.apply_model(s,{'provider':'openai-codex','model':'gpt-5.4-mini'})
        self.assertEqual(s.state['model'],'gpt-5.4-mini')
    def apply_model(self,s,body):
        if s.state['provider']!='omp': raise ValueError('当前 Agent 不支持切换模型')
        if s.state['busy']: raise ValueError('请先停止或完成当前任务')
        provider,model=body.get('provider',''),body.get('model','')
        if not provider or not model: raise ValueError('请同时指定 provider 和模型')
        s.state['model']=model; s.state['provider_id']=provider; s.touch(True)
    def test_omp_launch_carries_permission_model_and_thinking(self):
        s=self.session(); s.state.update(model='gpt-5.4-mini',thinking='xhigh',permissionMode='write')
        process=type('Process',(),{})()
        with patch.object(broker.subprocess,'Popen',return_value=process) as popen, \
             patch.object(broker.threading,'Thread'):
            s.launch()
        args=popen.call_args.args[0]
        popen.call_args.kwargs['stderr'].close()
        self.assertEqual(args[args.index('--approval-mode')+1],'write')
        self.assertEqual(args[args.index('--model')+1],'gpt-5.4-mini')
        self.assertEqual(args[args.index('--thinking')+1],'xhigh')
    def test_qoder_prompt_carries_current_permission_and_server_selection(self):
        s=self.session('qoder'); s.state['permissionMode']='dontAsk'
        sent=[]; s.send=lambda value:sent.append(value)
        s.process=type('Process',(),{'poll':lambda self:None})()
        s.prompt({'text':'continue','requestId':'qoder-permission'})
        self.assertEqual(sent[-1],{'type':'prompt','id':'qoder-permission','message':'continue',
                                  'permissionMode':'dontAsk','model':''})
        self.assertEqual(s.summary()['permission'],{'selected':'dontAsk',
            'options':['default','acceptEdits','plan','dontAsk','auto','bypassPermissions'],'scope':'next-turn'})
        self.assertEqual(s.snapshot()['permission'],s.summary()['permission'])

        selected=self.session('qoderintl'); selected.state.update(model='qoder-pro',thinking='high',
            qoderOuterProvider='trusted-provider',qoderContextWindow=131072)
        selected_sent=[]; selected.send=lambda value:selected_sent.append(value)
        selected.process=type('Process',(),{'poll':lambda self:None})()
        selected.prompt({'text':'work','requestId':'qoder-model','outerProvider':'forged'})
        self.assertEqual(selected_sent[-1],{'type':'prompt','id':'qoder-model','message':'work',
            'permissionMode':'default','model':'qoder-pro','thinking':'high',
            'outerProvider':'trusted-provider','contextWindow':131072})
    def test_available_commands_reach_snapshot_without_churning_revision(self):
        s=self.session()
        commands=[{'name':'compact','description':'Compact the conversation',
                   'input':{'hint':'[soft|remote|snapcompact] [focus]'},
                   'subcommands':[{'name':'soft','description':'Summarize locally'}],'source':'builtin'},
                  {'name':'model','aliases':['models'],'description':'Show current model selection','source':'builtin'},
                  {'name':'','description':'nameless entries are dropped'}]
        s.event({'type':'available_commands_update','commands':commands})
        listed=s.snapshot()['commands']
        self.assertEqual([c['name'] for c in listed],['compact','model'])
        self.assertEqual(listed[0]['subcommands'][0]['name'],'soft')
        # The runtime re-sends the whole list as each extension mounts, so an
        # unchanged list must not bump the revision the Mac polls on.
        before=s.state['revision']
        s.event({'type':'available_commands_update','commands':commands})
        self.assertEqual(s.state['revision'],before)
        s.event({'type':'available_commands_update','commands':commands[:1]})
        self.assertGreater(s.state['revision'],before)
        # Commands stay out of the polled summary; only the selected session reads them.
        self.assertNotIn('commands',s.summary())
        # Qoder has no such event, so its sessions never gain a command list.
        q=self.session('qoder')
        q.event({'type':'available_commands_update','commands':commands})
        self.assertIsNone(q.snapshot().get('commands'))
    def test_qoder_tool_link_and_stream(self):
        s=self.session('qoder')
        s.event({'type':'stream_event','event':{'type':'message_start'}})
        s.event({'type':'stream_event','event':{'type':'content_block_start','content_block':{'type':'text','text':''}}})
        s.event({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'你好'}}})
        self.assertEqual(s.snapshot()['messages'][-1]['content'][0]['text'],'你好')
        s.event({'type':'assistant','uuid':'result','message':{'role':'assistant','content':[{'type':'text','text':'你好'}]}})
        self.assertEqual(len(s.snapshot()['messages']),1)
        tool=broker.normalize({'role':'user','content':[{'type':'tool_result','tool_use_id':'x','content':'ok'}]},'tool')
        self.assertEqual(tool['content'][0]['tool_call_id'],'x')
        source={'kind':'activity_summary','provider':'codex','summaryParts':['Inspecting']}
        thought=broker.normalize({'role':'assistant','content':[{'type':'thinking','thinking':'raw','source':source}]},'thought')
        self.assertEqual(thought['content'][0]['source'],source)
    def test_claude_user_role_results_and_skills_do_not_open_turns(self):
        s = self.session('claude')
        s.upsert({'role':'user','content':'inspect'}, 'prompt')
        s.event({'type':'assistant','uuid':'call','message':{'role':'assistant','content':[
            {'type':'tool_use','id':'skill','name':'Skill','input':{'skill':'example'}}]}})
        for i in range(104):
            s.event({'type':'user','uuid':f'result-{i}','message':{'role':'user','content':[
                {'type':'tool_result','tool_use_id':'skill','content':'done'}]}})
        s.event({'type':'user','uuid':'old-skill','message':{'role':'user','content':
            'Base directory for this skill: /fixture/skill\n\n' + 'private instructions\n' * 6000}})
        s.event({'type':'user','uuid':'new-context','isSynthetic':True,'message':
            {'role':'user','content':'runtime context without a textual envelope'}})
        self.assertEqual(s.prompt_indices, [0])
        self.assertEqual(s.snapshot(turns='1')['messages'][0]['id'], 'prompt')
        context = s.state['messages'][-1]['content'][0]
        self.assertEqual(context['source'], {'kind':'runtime_context','provider':'claude'})
        # A real mixed prompt/result or attachment still starts a user turn.
        self.assertTrue(broker.is_user_prompt(broker.normalize({'role':'user','content':[
            {'type':'tool_result','tool_use_id':'skill','content':'done'}, {'type':'text','text':'continue'}]}, 'mixed')))
        restored = broker.Session(json.loads(json.dumps(s.state)))
        self.assertEqual(restored.prompt_indices, [0])

    def test_claude_subagent_messages_do_not_replace_main_stream(self):
        s = self.session('claude')
        with patch.object(broker.threading, 'Timer'):
            s.event({'type':'stream_event','event':{'type':'content_block_start','index':0,
                'content_block':{'type':'text','text':'main'}}})
            # The roster change that registers the child is a session change; the
            # transcript appends after it are not.
            s.event({'type':'system','subtype':'task_started','task_id':'task-1','tool_use_id':'agent-tool',
                'task_type':'local_agent','description':'Explore'})
            before = s.snapshot(); page = s.snapshot(turns='50'); revision = s.state['revision']
            messages = json.loads(json.dumps(s.state['messages'])); partial = json.loads(json.dumps(s.state['partial']))
            for kind in ['assistant', 'user', 'stream_event']:
                s.event({'type':kind,'parent_tool_use_id':'agent-tool','uuid':'child-'+kind,
                    'message':{'role':kind,'content':'child'},'event':{'type':'message_start'}})
            self.assertEqual(s.state['revision'], revision)
            self.assertEqual((s.state['messages'], s.state['partial']), (messages, partial))
            self.assertEqual(s.snapshot()['messages'], before['messages'])
            self.assertEqual(s.snapshot(revision=str(revision), start=str(page['history']['start']),
                epoch=page['history']['epoch']), {'unchanged':True})
            # The child's assistant and user messages are in its own transcript;
            # its stream event is not.
            transcript = s.subagent_page('agent-tool')
            self.assertEqual([(m['id'], m['role'], m['content'][0]['text']) for m in transcript['messages']],
                [('child-assistant','assistant','child'), ('child-user','user','child')])
            self.assertEqual(transcript['entry']['messageCount'], 2)
        # Parent tool results and approvals still reach the main client.
        s.event({'type':'user','uuid':'parent-result','parent_tool_use_id':None,
            'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'agent-tool','content':'report'}]}})
        self.assertEqual(s.state['messages'][0]['content'][0]['output'], 'report')
        self.assertEqual(s.state['partial']['content'][0]['text'], 'main')
        # A task event already reported on this child, so its tool_result cannot end it.
        self.assertEqual(s.snapshot()['subagents'][0]['status'], 'running')
        s.event({'type':'interaction','id':'child-approval','name':'Bash','input':{}})
        self.assertEqual(s.state['interactions'][0]['id'], 'child-approval')

    def test_claude_stream_indices_survive_per_block_completion(self):
        s = self.session('claude')
        def stream(event): s.event({'type':'stream_event','event':event})
        stream({'type':'message_start'})
        for i, kind, text in [(0,'thinking','plan'), (1,'text','first'), (2,'text','second')]:
            stream({'type':'content_block_start','index':i,'content_block':{'type':kind,kind:''}})
            stream({'type':'content_block_delta','index':i,'delta':{'type':kind+'_delta',kind:text}})
            self.assertEqual(s.snapshot()['messages'][-1]['content'][0][kind], text)
            s.event({'type':'assistant','uuid':f'block-{i}','message':{
                'id':'same-api-message','role':'assistant','content':[{'type':kind,kind:text}]}})
            stream({'type':'content_block_stop','index':i})
            self.assertNotIn('partial', s.state)
        stream({'type':'message_stop'})
        self.assertEqual([m['id'] for m in s.state['messages']], ['block-0','block-1','block-2'])
        self.assertEqual([m['content'][0].get('text') for m in s.state['messages'][1:]], ['first','second'])

    def test_claude_launch_uses_claude_worker_and_binary(self):
        s=self.session('claude'); s.state['permissionMode']='default'
        process=type('Process',(),{})()
        with patch.object(broker.subprocess,'Popen',return_value=process) as popen, \
             patch.object(broker.threading,'Thread'), \
             patch.object(broker,'proxy_aware_spawn_env',return_value={'https_proxy':'http://127.0.0.1:7890'}), \
             patch.object(broker.shutil,'which',return_value='/usr/local/bin/claude'):
            s.launch()
        args=popen.call_args.args[0]
        popen.call_args.kwargs['stderr'].close()
        self.assertEqual(args[0],'node')
        self.assertTrue(args[1].endswith('claude-worker.mjs'))
        cfg=json.loads(args[2])
        self.assertEqual(cfg['binary'],'/usr/local/bin/claude')
        self.assertEqual(cfg['cwd'],'/tmp')
        # Subagent text is forwarded by default (probe 2026-10-18).
        self.assertIs(cfg['forwardSubagentText'],True)
        # The worker needs the proxy env, otherwise the CLI's phone-home calls stall silently.
        self.assertEqual(popen.call_args.kwargs['env'],{'https_proxy':'http://127.0.0.1:7890'})
        with patch.object(broker,'CLAUDE_FORWARD_SUBAGENT_TEXT',False), \
             patch.object(broker.subprocess,'Popen',return_value=process) as popen, \
             patch.object(broker.threading,'Thread'), patch.object(broker,'proxy_aware_spawn_env',return_value={}), \
             patch.object(broker.shutil,'which',return_value='/usr/local/bin/claude'):
            s.launch()
        popen.call_args.kwargs['stderr'].close()
        self.assertIs(json.loads(popen.call_args.args[0][2])['forwardSubagentText'],False)
    def test_claude_interrupt_is_not_an_error(self):
        s=self.session('claude');s.state['cancelled']=True
        s.event({'type':'result','is_error':True,'errors':['Operation aborted']})
        s.event({'type':'worker_error','message':'Operation aborted'})
        s.event({'type':'agent_end'});self.assertIsNone(s.state['error']);self.assertEqual(s.state['completed'],0)
    def test_claude_prompt_carries_current_permission_mode(self):
        s=self.session('claude'); s.state['permissionMode']='acceptEdits'
        sent=[]; s.send=lambda value:sent.append(value)
        s.process=type('Process',(),{'poll':lambda self:None})()
        s.prompt({'text':'continue','requestId':'claude-permission'})
        self.assertEqual(sent[-1],{'type':'prompt','id':'claude-permission','message':'continue','permissionMode':'acceptEdits'})
        self.assertEqual(s.summary()['permission'],{'selected':'acceptEdits',
            'options':['default','acceptEdits','plan','bypassPermissions'],'scope':'next-turn'})
        self.assertEqual(s.snapshot()['permission'],s.summary()['permission'])
    def test_claude_prompt_stores_and_forwards_attachments(self):
        s=self.session('claude'); s.state['permissionMode']='default'
        sent=[]; s.send=lambda value:sent.append(value)
        s.process=type('Process',(),{'poll':lambda self:None})()
        data=base64.b64encode(b'png-bytes').decode()
        receipt=s.prompt({'text':'描述这张图','requestId':'claude-attachment','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':data}]})
        message=sent[-1]
        self.assertEqual(message['type'],'prompt')
        stored=message['attachments'][0]
        self.assertEqual(stored['name'],'shot.png')
        self.assertEqual(stored['mediaType'],'image/png')
        self.assertEqual(pathlib.Path(stored['path']).read_bytes(),b'png-bytes')
        self.assertIn('[图片: shot.png]',s.state['messages'][0]['content'][0]['text'])
        # The same requestId replays the receipt without resending; a different
        # payload under that id is rejected by the digest.
        again=s.prompt({'text':'描述这张图','requestId':'claude-attachment','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':data}]})
        self.assertEqual(again,receipt)
        self.assertEqual(len([m for m in sent if m.get('id')=='claude-attachment']),1)
        with self.assertRaises(ValueError):
            s.prompt({'text':'别的','requestId':'claude-attachment'})
    def test_claude_prompt_allows_attachment_only_message(self):
        s=self.session('claude')
        sent=[]; s.send=lambda value:sent.append(value)
        s.process=type('Process',(),{'poll':lambda self:None})()
        s.prompt({'text':'','requestId':'claude-image-only','attachments':[
            {'name':'notes.txt','mediaType':'text/plain','data':base64.b64encode(b'notes').decode()}]})
        self.assertIn('[附件: notes.txt]',s.state['messages'][0]['content'][0]['text'])
        self.assertEqual(s.state['title'],'[附件: notes.txt]')
    def test_attachments_rejected_for_other_providers(self):
        s=self.session('qoder')
        s.process=type('Process',(),{'poll':lambda self:None})()
        with self.assertRaises(ValueError):
            s.prompt({'text':'hi','requestId':'qoder-attachment','attachments':[
                {'name':'a.png','mediaType':'image/png','data':base64.b64encode(b'x').decode()}]})
    def test_normalize_marks_image_blocks(self):
        message=broker.normalize({'role':'user','content':[
            {'type':'image','source':{'type':'base64','media_type':'image/png','data':'x'}}]},'img')
        self.assertEqual(message['content'],[{'type':'text','text':'[图片]'}])
    def test_claude_result_reports_context_usage(self):
        s=self.session('claude')
        s.event({'type':'agent_start'})
        # The window fill is the latest reply's per-request usage, not the turn total.
        s.event({'type':'assistant','uuid':'a1','message':{'role':'assistant','content':[{'type':'text','text':'先想'}],
            'usage':{'input_tokens':100,'cache_read_input_tokens':8000,'cache_creation_input_tokens':200,'output_tokens':50}}})
        s.event({'type':'assistant','uuid':'a2','message':{'role':'assistant','content':[{'type':'text','text':'再答'}],
            'usage':{'input_tokens':120,'cache_read_input_tokens':9000,'cache_creation_input_tokens':200,'output_tokens':60}}})
        # result.usage sums every API request of the turn; it must not feed the meter.
        s.event({'type':'result','session_id':'sess','usage':{'input_tokens':120000,
            'cache_read_input_tokens':2500000,'cache_creation_input_tokens':90000,'output_tokens':50},
            'modelUsage':{'claude-opus-4-7':{'contextWindow':200000}}})
        ctx=s.state['context']
        self.assertEqual((ctx['tokens'],ctx['limit']),(9380,200000))
        self.assertTrue(ctx['reportedAt'])
        self.assertEqual(s.summary()['context']['tokens'],9380)
        # A zeroed (crashed) result must not overwrite a real reading.
        s.event({'type':'result','session_id':'sess','usage':{},'modelUsage':{}})
        self.assertEqual(s.state['context']['tokens'],9380)
        # A turn without any assistant reply keeps the previous reading.
        s.event({'type':'agent_start'})
        s.event({'type':'result','session_id':'sess','usage':{'input_tokens':999},
            'modelUsage':{'claude-opus-4-7':{'contextWindow':200000}}})
        self.assertEqual(s.state['context']['tokens'],9380)
    def test_claude_context_usage_event_resolves_window(self):
        s=self.session('claude')
        s.event({'type':'agent_start'})
        s.event({'type':'assistant','uuid':'a1','message':{'role':'assistant','content':[{'type':'text','text':'答'}],
            'usage':{'input_tokens':100,'cache_read_input_tokens':8000,'cache_creation_input_tokens':200,'output_tokens':50}}})
        s.event({'type':'result','session_id':'sess','usage':{'input_tokens':90000},
            'modelUsage':{'claude-opus-4-7':{'contextWindow':1000000}}})
        self.assertEqual((s.state['context']['tokens'],s.state['context']['limit']),(8350,1000000))
        # The resolved autocompact window replaces the model's declared limit.
        s.event({'type':'context_usage','model':'claude-opus-4-7','tokens':8350,'limit':200000})
        self.assertEqual((s.state['context']['tokens'],s.state['context']['limit']),(8350,200000))
        self.assertTrue(s.state['context']['reportedAt'])
        # A missing limit never clobbers a valid reading.
        s.event({'type':'context_usage','model':'claude-opus-4-7','tokens':8350})
        self.assertEqual(s.state['context']['limit'],200000)
    def test_claude_tool_link_and_stream(self):
        s=self.session('claude')
        s.event({'type':'stream_event','event':{'type':'message_start'}})
        s.event({'type':'stream_event','event':{'type':'content_block_start','content_block':{'type':'text','text':''}}})
        s.event({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'你好'}}})
        self.assertEqual(s.snapshot()['messages'][-1]['content'][0]['text'],'你好')
        s.event({'type':'assistant','uuid':'result','message':{'role':'assistant','content':[{'type':'text','text':'你好'}]}})
        self.assertEqual(len(s.snapshot()['messages']),1)
        s.event({'type':'interaction','id':'approval','name':'Bash','input':{'command':'ls'}})
        self.assertEqual(s.snapshot()['interactions'][0]['id'],'approval')
        s.event({'type':'interaction_cancel','id':'approval'})
        self.assertEqual(s.snapshot()['interactions'],[])

class FakeCodex:
    def __init__(self, *args, **kwargs):
        self.calls=[]; self.responses=[]; self.closed=False
        owner=self
        self.process=type('Process',(),{'poll':lambda _self:0 if owner.closed else None})()
        self.results={
            'thread/start':{'thread':{'id':'native-thread','model':'gpt-codex','reasoningEffort':'medium'}},
            'thread/resume':{'thread':{'id':'native-thread','model':'gpt-codex','reasoningEffort':'medium'}},
            'thread/items/list':{'data':[],'nextCursor':None},
            'turn/start':{'turn':{'id':'turn-native','status':'inProgress'}},
        }
        self.on_frame=None; self.on_exit=None
    def initialize(self): self.calls.append(('initialize',{}))
    def request(self, method, params, timeout=60):
        self.calls.append((method,params))
        result=self.results.get(method,{})
        if isinstance(result,list): return result.pop(0)
        return result
    def respond(self, request_id, result=None, error=None):
        self.responses.append((request_id,result,error))
    def close(self): self.closed=True

class CodexRuntimeIsolationTests(unittest.TestCase):
    def test_marker_changes_only_new_runtime_selection(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(broker, 'ROOT', pathlib.Path(directory)), \
             patch.dict(os.environ, {'CODEX_HOME':'/original/codex-home'}):
            marker = broker.ROOT/'codex-home'
            self.assertEqual(broker.codex_home(), '/original/codex-home')
            marker.write_text('/custom/codex-home\n')
            self.assertEqual(broker.codex_home(), '/custom/codex-home')
            self.assertEqual(broker.codex_home(legacy=True), '/original/codex-home')
            for value in ('', 'relative/home', '/custom\n/other'):
                marker.write_text(value)
                with self.subTest(value=value), self.assertRaises(ValueError): broker.codex_home()

    def test_explicit_home_is_scoped_to_the_spawned_codex_process(self):
        with patch.dict(os.environ, {'CODEX_HOME':'/original/home'}, clear=True), \
             patch.object(broker.shutil, 'which', return_value='/fixture/codex'), \
             patch.object(broker, 'proxy_aware_spawn_env', return_value={'PATH':'/usr/bin','CODEX_HOME':'/original/home'}), \
             patch.object(broker.subprocess, 'Popen') as launch, patch.object(broker.threading.Thread, 'start'):
            broker.CodexAppServer('/tmp', home='/isolated/home')
            self.assertEqual(launch.call_args.kwargs['env']['CODEX_HOME'], '/isolated/home')
            self.assertEqual(os.environ['CODEX_HOME'], '/original/home')
            self.assertEqual(launch.call_args.args[0], ['/fixture/codex','app-server','--listen','stdio://'])

    def test_account_check_distinguishes_custom_provider_without_exposing_account(self):
        cases = [({'requiresOpenaiAuth':False,'account':None}, 'provider-managed'),
                 ({'requiresOpenaiAuth':True,'account':None}, 'missing'),
                 ({'requiresOpenaiAuth':True,'account':{'email':'PRIVATE'}}, 'present'),
                 ({}, 'missing')]
        for account, expected in cases:
            fake = FakeCodex(); fake.results['account/read'] = account
            with self.subTest(account=account), patch.object(broker, 'CodexAppServer', return_value=fake) as factory:
                self.assertEqual(broker.codex_credential_status('/selected/home'), expected)
                factory.assert_called_once_with(str(broker.ROOT), home='/selected/home')
                self.assertEqual(fake.calls, [('initialize',{}),('account/read',{'refreshToken':False})])
                self.assertTrue(fake.closed)

    def test_model_catalog_cache_is_separate_for_each_home(self):
        homes = []
        def create(*args, **kwargs):
            home = kwargs['home']; homes.append(home)
            fake = FakeCodex()
            fake.results['model/list'] = {'data':[{'id':home,'model':home,'displayName':home}], 'nextCursor':None}
            return fake
        with patch.object(broker, 'CODEX_MODELS', None), patch.object(broker, 'CodexAppServer', side_effect=create):
            self.assertEqual(broker.codex_catalog('/one')[0]['id'], '/one')
            self.assertEqual(broker.codex_catalog('/two')[0]['id'], '/two')
            self.assertEqual(broker.codex_catalog('/one')[0]['id'], '/one')
            self.assertEqual(homes, ['/one','/two'])

    def test_legacy_and_pinned_sessions_keep_their_original_home_and_provider(self):
        state = dict(id='isolated',provider='codex',cwd=folder.name,title='Codex',model='gpt-codex',
                     busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None)
        with patch.object(broker, 'codex_home', return_value='/original/home') as home:
            session = broker.Session(state)
            self.assertEqual(session.state['codexHome'], '/original/home')
            home.assert_called_once_with(legacy=True)
        state.update(codexHome='/pinned/home', provider_id='custom-provider')
        with patch.object(broker, 'codex_home', side_effect=AssertionError('pinned session must not follow new defaults')):
            session = broker.Session(state)
            self.assertEqual(session.codex_open_params()['modelProvider'], 'custom-provider')
            with patch.object(broker, 'CodexAppServer', return_value=FakeCodex()) as factory:
                session.codex_ensure(False)
                self.assertEqual(factory.call_args.kwargs['home'], '/pinned/home')

class CodexProtocolTests(unittest.TestCase):
    def setUp(self):
        broker.SESSIONS.clear(); broker.CODEX_MODELS=None
    def session(self, identity='native-thread', resume=True):
        state=dict(id=identity,provider='codex',cwd=folder.name,title='Codex',model='gpt-codex',thinking='medium',
                   busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None)
        if resume: state['resume']='native-thread'
        s=broker.Session(state); fake=FakeCodex(); s.codex=fake; s.codex_attached=resume
        broker.SESSIONS[identity]=s
        return s,fake
    def test_thread_start_uses_native_id(self):
        s,fake=self.session('temporary',False)
        native=s.codex_start_thread()
        self.assertEqual(native,'native-thread')
        self.assertEqual(s.state['id'],'native-thread')
        self.assertIs(broker.SESSIONS['native-thread'],s)
        self.assertNotIn('temporary',broker.SESSIONS)
        method,params=fake.calls[-1]
        self.assertEqual(method,'thread/start')
        self.assertEqual(params['cwd'],folder.name)
        self.assertEqual(params['approvalPolicy'],'on-request')
        self.assertEqual(params['approvalsReviewer'],'user')
        self.assertEqual(params['sandbox'],'workspace-write')
    def test_permission_modes_survive_restart_and_reach_resume_and_turn(self):
        expected = {'read-only': ('on-request', 'read-only', 'readOnly'),
                    'workspace-ask': ('on-request', 'workspace-write', 'workspaceWrite'),
                    'workspace-auto': ('never', 'workspace-write', 'workspaceWrite'),
                    'full-access': ('never', 'danger-full-access', 'dangerFullAccess')}
        for mode, (policy, sandbox, turn_sandbox) in expected.items():
            with self.subTest(mode=mode):
                s,fake=self.session(); s.state['permissionMode']=mode; s.persist()
                restored=broker.Session(json.loads(s.path.read_text()))
                restored.codex=fake; restored.codex_attached=False
                restored.codex_ensure(True)
                params=next(params for method,params in fake.calls if method=='thread/resume')
                self.assertEqual((params['approvalPolicy'],params['approvalsReviewer'],params['sandbox']), (policy,'user',sandbox))
                restored.prompt({'text':'test','requestId':'permission-'+mode})
                turn=next(params for method,params in fake.calls if method=='turn/start')
                self.assertEqual((turn['approvalPolicy'],turn['approvalsReviewer'],turn['sandboxPolicy']), (policy,'user',{'type':turn_sandbox}))

    def test_legacy_permission_modes_restore_safely(self):
        for stored, expected in [(None,'workspace-ask'), ('ask','workspace-ask'),
                                 ('auto-review','workspace-ask'), ('full-access','full-access'),
                                 ('unknown','workspace-ask')]:
            with self.subTest(stored=stored):
                state=dict(id='legacy',provider='codex',cwd=folder.name,title='Legacy',model='',
                           busy=False,archived=False,updated=0,revision=0,completed=0,
                           messages=[],interactions=[],error=None)
                if stored is not None: state['permissionMode']=stored
                self.assertEqual(broker.Session(state).state['permissionMode'],expected)

    def test_prompt_sends_images_as_local_image_items(self):
        s,fake=self.session()
        data=base64.b64encode(b'png-bytes').decode()
        receipt=s.prompt({'text':'描述这张图','requestId':'codex-attachment','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':data}]})
        self.assertEqual(receipt['status'],'accepted')
        turn=next(params for method,params in fake.calls if method=='turn/start')
        self.assertEqual([i['type'] for i in turn['input']],['text','localImage'])
        self.assertEqual(turn['input'][0],{'type':'text','text':'描述这张图'})
        self.assertEqual(pathlib.Path(turn['input'][1]['path']).read_bytes(),b'png-bytes')
        self.assertIn('[图片: shot.png]',s.state['messages'][0]['content'][0]['text'])
        # The same requestId replays the receipt without starting another turn.
        again=s.prompt({'text':'描述这张图','requestId':'codex-attachment','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':data}]})
        self.assertEqual(again,receipt)
        self.assertEqual(len([c for c in fake.calls if c[0]=='turn/start']),1)

    def test_prompt_notes_non_image_attachments_in_text(self):
        s,fake=self.session()
        s.prompt({'text':'','requestId':'codex-file','attachments':[
            {'name':'notes.txt','mediaType':'text/plain','data':base64.b64encode(b'notes').decode()}]})
        turn=next(params for method,params in fake.calls if method=='turn/start')
        self.assertEqual([i['type'] for i in turn['input']],['text'])
        self.assertIn('notes.txt',turn['input'][0]['text'])
        self.assertIn(str(broker.ROOT/'attachments'),turn['input'][0]['text'])
        self.assertEqual(s.state['title'],'[附件: notes.txt]')

    def test_prompt_image_only_omits_empty_text_item(self):
        s,fake=self.session()
        s.prompt({'text':'','requestId':'codex-image-only','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':base64.b64encode(b'png-bytes').decode()}]})
        turn=next(params for method,params in fake.calls if method=='turn/start')
        self.assertEqual([i['type'] for i in turn['input']],['localImage'])

    def test_steer_rejects_attachments(self):
        s,fake=self.session()
        s.prompt({'text':'开始','requestId':'request-1'})
        with self.assertRaises(ValueError):
            s.steer({'text':'带图','requestId':'steer-img','attachments':[
                {'name':'a.png','mediaType':'image/png','data':base64.b64encode(b'x').decode()}]})
        self.assertEqual([c for c in fake.calls if c[0]=='turn/steer'],[])

    def test_user_message_echo_keeps_attachment_marks(self):
        s,fake=self.session()
        s.prompt({'text':'描述这张图','requestId':'codex-attachment','attachments':[
            {'name':'shot.png','mediaType':'image/png','data':base64.b64encode(b'png-bytes').decode()}]})
        # Codex echoes the submitted user message without image data; the record
        # made at send time carries the [图片] mark and must survive.
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{
            'type':'userMessage','id':'u1','clientId':'codex-attachment','content':[{'type':'text','text':'描述这张图'}]}}})
        self.assertEqual(s.state['messages'][0]['content'][0]['text'],'描述这张图\n[图片: shot.png]')
        self.assertEqual(s.state['requests']['codex-attachment']['runtimeId'],'u1')

    def test_context_uses_last_request_and_shrinks_after_compaction(self):
        s,fake=self.session()
        for cumulative,current in [(300000,80000),(600000,12000)]:
            s.codex_frame(fake,{'method':'thread/tokenUsage/updated','params':{
                'threadId':'native-thread','tokenUsage':{
                    'total':{'totalTokens':cumulative},'last':{'totalTokens':current},
                    'modelContextWindow':200000}}})
            self.assertEqual(s.state['context']['tokens'],current)
            self.assertEqual(s.summary()['context']['tokens'],current)
        s.codex_frame(fake,{'method':'item/started','params':{
            'threadId':'native-thread','item':{'type':'contextCompaction','id':'compact'}}})
        self.assertIsNone(s.state['context'])
        s.codex_frame(fake,{'method':'thread/tokenUsage/updated','params':{
            'threadId':'native-thread','tokenUsage':{
                'total':{'totalTokens':999999},'modelContextWindow':200000}}})
        self.assertIsNone(s.state['context']['tokens'])

    def test_restored_codex_context_waits_for_fresh_usage(self):
        s,_=self.session()
        s.state['context']={'tokens':999999,'limit':200000}
        restored=broker.Session(dict(s.state))
        self.assertIsNone(restored.state['context'])

    def test_resume_hydrates_native_items_with_pagination(self):
        s,fake=self.session(); s.codex_attached=False
        fake.results['thread/resume']={'thread':{'id':'native-thread','model':'gpt-codex'}}
        fake.results['thread/items/list']=[
            {'data':[{'turnId':'t1','item':{'type':'userMessage','id':'u1','content':[{'type':'text','text':'问题'}]}}], 'nextCursor':'next'},
            {'data':[{'turnId':'t1','item':{'type':'agentMessage','id':'a1','text':'答案'}}], 'nextCursor':None}]
        s.codex_ensure(True)
        self.assertEqual([m['role'] for m in s.state['messages']],['user','assistant'])
        self.assertEqual(s.state['messages'][1]['content'][0]['text'],'答案')
        resume=next(params for method,params in fake.calls if method=='thread/resume')
        self.assertTrue(resume['excludeTurns'])
        pages=[params for method,params in fake.calls if method=='thread/items/list']
        self.assertEqual(pages[0],{'threadId':'native-thread','sortDirection':'asc','limit':100})
        self.assertEqual(pages[1]['cursor'],'next')

    def test_reasoning_summary_metadata_streams_and_reconciles(self):
        s,fake=self.session(); s.state['turnId']='turn-native'
        s.codex_frame(fake,{'method':'item/reasoning/summaryPartAdded','params':{
            'threadId':'native-thread','turnId':'turn-native','itemId':'r1','summaryIndex':0}})
        s.codex_frame(fake,{'method':'item/reasoning/summaryTextDelta','params':{
            'threadId':'native-thread','turnId':'turn-native','itemId':'r1','summaryIndex':0,'delta':'Inspecting'}})
        s.codex_frame(fake,{'method':'item/reasoning/summaryPartAdded','params':{
            'threadId':'native-thread','turnId':'turn-native','itemId':'r1','summaryIndex':1}})
        s.codex_frame(fake,{'method':'item/reasoning/summaryTextDelta','params':{
            'threadId':'native-thread','turnId':'turn-native','itemId':'r1','summaryIndex':1,'delta':'Editing'}})
        s.codex_frame(fake,{'method':'item/reasoning/textDelta','params':{
            'threadId':'native-thread','turnId':'turn-native','itemId':'r1','contentIndex':0,'delta':'private chain'}})
        part=next(m for m in s.state['messages'] if m['id']=='codex:r1')['content'][0]
        self.assertEqual(part['thinking'],'Inspecting\nEditing\nprivate chain')
        self.assertEqual(part['source'],{'kind':'activity_summary','provider':'codex','itemId':'r1',
            'summaryParts':['Inspecting','Editing'],'state':'streaming','turnId':'turn-native'})
        self.assertNotIn('private chain',json.dumps(part['source']))
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{
            'type':'reasoning','id':'r1','summary':['Final summary'],'content':['final private chain']}}})
        final=next(m for m in s.state['messages'] if m['id']=='codex:r1')['content'][0]
        self.assertEqual(final['thinking'],'Final summary\nfinal private chain')
        self.assertEqual(final['source']['summaryParts'],['Final summary'])
        self.assertEqual(final['source']['state'],'final')

        hydrated,_=self.session('hydrated')
        hydrated.codex_item({'type':'reasoning','id':'history','summary':['Hydrated summary'],
                              'content':['private history']},completed=True)
        restored=next(m for m in hydrated.state['messages'] if m['id']=='codex:history')['content'][0]
        self.assertEqual(restored['source']['summaryParts'],['Hydrated summary'])
        self.assertEqual(restored['source']['state'],'final')

    def test_turn_start_steer_and_stream_completion(self):
        s,fake=self.session()
        receipt=s.prompt({'text':'开始','requestId':'request-1'})
        self.assertEqual(receipt['status'],'accepted')
        method,params=next(call for call in fake.calls if call[0]=='turn/start')
        self.assertEqual(params,{'threadId':'native-thread','input':[{'type':'text','text':'开始'}],
                                 'clientUserMessageId':'request-1','model':'gpt-codex','effort':'medium',
                                 'approvalPolicy':'on-request','approvalsReviewer':'user','sandboxPolicy':{'type':'workspaceWrite'}})
        steer=s.steer({'text':'只读分析','requestId':'steer-1'})
        self.assertEqual(steer['status'],'accepted')
        steer_params=next(params for method,params in fake.calls if method=='turn/steer')
        self.assertEqual(steer_params['expectedTurnId'],'turn-native')
        self.assertEqual(steer_params['clientUserMessageId'],'steer-1')

        s.codex_frame(fake,{'method':'item/agentMessage/delta','params':{'threadId':'native-thread','itemId':'a1','delta':'草稿'}})
        self.assertEqual(s.state['messages'][-1]['content'][0]['text'],'草稿')
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{'type':'agentMessage','id':'a1','text':'最终答案'}}})
        self.assertEqual(s.state['messages'][-1]['content'][0]['text'],'最终答案')
        s.codex_frame(fake,{'method':'item/reasoning/summaryTextDelta','params':{'threadId':'native-thread','itemId':'r1','summaryIndex':0,'delta':'分析中'}})
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{'type':'reasoning','id':'r1','summary':['最终分析'],'content':[]}}})
        reasoning=next(m for m in s.state['messages'] if m['id']=='codex:r1')
        self.assertEqual(reasoning['content'][0]['thinking'],'最终分析')
        s.codex_frame(fake,{'method':'item/plan/delta','params':{'threadId':'native-thread','itemId':'p1','delta':'计划草稿'}})
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{'type':'plan','id':'p1','text':'最终计划'}}})
        plan=next(m for m in s.state['messages'] if m['id']=='codex:p1')
        self.assertEqual(plan['content'][0]['thinking'],'最终计划')
        s.codex_frame(fake,{'method':'item/started','params':{'threadId':'native-thread','item':{'type':'commandExecution','id':'c1','command':'pwd','cwd':folder.name,'status':'inProgress'}}})
        s.codex_frame(fake,{'method':'item/commandExecution/outputDelta','params':{'threadId':'native-thread','itemId':'c1','delta':'partial'}})
        s.codex_frame(fake,{'method':'item/completed','params':{'threadId':'native-thread','item':{'type':'commandExecution','id':'c1','command':'pwd','cwd':folder.name,'status':'completed','aggregatedOutput':'final'}}})
        tool=next(m for m in s.state['messages'] if m['id']=='codex-tool:c1')
        result=next(m for m in s.state['messages'] if m['id']=='codex-result:c1')
        self.assertEqual(tool['content'][0]['tool_name'],'shell')
        self.assertEqual(result['content'][0]['output'][0]['text'],'final')
        s.codex_frame(fake,{'method':'thread/tokenUsage/updated','params':{'threadId':'native-thread','tokenUsage':{'total':{'totalTokens':999999},'last':{'totalTokens':1234},'modelContextWindow':200000}}})
        self.assertEqual(s.state['context']['tokens'],1234)
        self.assertEqual(s.state['context']['limit'],200000)
        self.assertGreater(s.state['context']['reportedAt'],0)
        s.codex_frame(fake,{'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'turn-native','status':'completed'}}})
        self.assertFalse(s.state['busy']); self.assertEqual(s.state['completed'],1)
        self.assertEqual(s.state['turnState'],'completed')
    def test_approvals_questions_and_unknown_reverse_requests(self):
        s,fake=self.session()
        requests=[
            (1,'item/commandExecution/requestApproval',{'threadId':'native-thread','command':['git','status'],'cwd':folder.name},True,{'decision':'accept'}),
            (2,'item/fileChange/requestApproval',{'threadId':'native-thread','itemId':'f1','reason':'edit'},False,{'decision':'decline'}),
            (3,'item/permissions/requestApproval',{'threadId':'native-thread','permissions':{'network':True}},True,{'permissions':{'network':True},'scope':'turn'}),
            (4,'item/permissions/requestApproval',{'threadId':'native-thread','permissions':{'network':True}},False,{'permissions':{},'scope':'turn'}),
            (5,'execCommandApproval',{'conversationId':'native-thread','command':['pwd']},False,{'decision':{'denied':{'rejection':'用户在 Perch 中拒绝了该操作'}}}),
        ]
        for wire,method,params,allow,expected in requests:
            s.codex_frame(fake,{'id':wire,'method':method,'params':params})
            interaction='codex-request-'+str(wire)
            self.assertIn(interaction,[x['id'] for x in s.state['interactions']])
            s.codex_answer(interaction,{'allow':allow})
            self.assertEqual(fake.responses[-1],(wire,expected,None))
        s.codex_frame(fake,{'id':6,'method':'item/tool/requestUserInput','params':{'threadId':'native-thread','questions':[
            {'id':'first','question':'Choose','header':'A','options':[{'label':'one'}]},
            {'id':'second','question':'Choose','header':'B','options':[{'label':'two'}]}]}})
        questions=s.state['interactions'][0]['input']['questions']
        self.assertEqual([q['question'] for q in questions],['Choose','Choose (2)'])
        s.codex_answer('codex-request-6',{'allow':True,'answers':{'Choose':'one','Choose (2)':'two'}})
        self.assertEqual(fake.responses[-1][1],{'answers':{'first':{'answers':['one']},'second':{'answers':['two']}}})
        s.codex_frame(fake,{'id':7,'method':'mcpServer/elicitation/request','params':{'threadId':'native-thread','serverName':'demo','message':'Configure','requestedSchema':{
            'type':'object','properties':{'enabled':{'title':'Enabled','type':'boolean'},'tags':{'title':'Tags','type':'array','items':{'type':'string'}}}}}})
        s.codex_answer('codex-request-7',{'allow':True,'answers':{'Enabled':'yes','Tags':'one, two'}})
        self.assertEqual(fake.responses[-1][1],{'action':'accept','content':{'enabled':True,'tags':['one','two']}})
        s.codex_frame(fake,{'id':8,'method':'future/request','params':{'threadId':'native-thread'}})
        self.assertEqual(fake.responses[-1],(8,None,{'code':-32601,'message':'unsupported by the Perch bridge'}))

class CodexHandlerContractTests(unittest.TestCase):
    def setUp(self):
        broker.TOKEN='test-token'; broker.SESSIONS.clear(); broker.CODEX_MODELS=None
        self.s,self.fake=CodexProtocolTests().session()
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def test_create_returns_native_thread_id_and_catalog_default(self):
        broker.SESSIONS.clear(); fake=FakeCodex()
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium','ultra'],'defaultThinking':'medium'}]
        with patch.object(broker,'codex_catalog',return_value=catalog), patch.object(broker,'CodexAppServer',side_effect=lambda *args,**kwargs:fake):
            code,payload=self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex'})
        self.assertEqual(code,200); self.assertEqual(payload['id'],'native-thread')
        self.assertEqual(payload['provider'],'codex'); self.assertEqual(payload['thinking'],'medium')
        self.assertEqual(payload['permission'],{'selected':'workspace-ask',
            'options':['read-only','workspace-ask','workspace-auto','full-access'],'scope':'new-session'})
        self.assertIn('native-thread',broker.SESSIONS)
    def test_create_passes_selected_permission_mode(self):
        catalog=[{'id':'gpt-codex','provider':'codex','thinking':[]}]
        expected=[('read-only','on-request','read-only'), ('workspace-ask','on-request','workspace-write'),
                  ('workspace-auto','never','workspace-write'), ('full-access','never','danger-full-access')]
        for mode, policy, sandbox in expected:
            with self.subTest(mode=mode):
                broker.SESSIONS.clear(); fake=FakeCodex()
                with patch.object(broker,'codex_catalog',return_value=catalog), patch.object(broker,'CodexAppServer',return_value=fake):
                    code,payload=self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex','permissionMode':mode})
                self.assertEqual(code,200)
                self.assertEqual(payload['permission']['selected'],mode)
                params=next(params for method,params in fake.calls if method=='thread/start')
                self.assertEqual((params['approvalsReviewer'],params['approvalPolicy'],params['sandbox']), ('user',policy,sandbox))
        with patch.object(broker,'codex_catalog',return_value=catalog):
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex','permissionMode':'ask'})[0],400)

    def test_only_qoder_permission_changes_are_persisted_for_the_next_turn(self):
        qoder=broker.Session(dict(id='qoder-permission',provider='qoder',cwd=folder.name,title='Qoder',model='',
            busy=True,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[{'id':'pending'}],error=None))
        broker.SESSIONS[qoder.state['id']]=qoder
        code,payload=self.request('/sessions/qoder-permission/permission',{'mode':'bypassPermissions'})
        self.assertEqual(code,200)
        self.assertEqual(payload['permission']['selected'],'bypassPermissions')
        self.assertEqual(json.loads(qoder.path.read_text())['permissionMode'],'bypassPermissions')
        self.assertEqual(qoder.summary()['permission'],{'selected':'bypassPermissions',
            'options':['default','acceptEdits','plan','dontAsk','auto','bypassPermissions'],'scope':'next-turn'})
        self.assertEqual(self.request('/sessions/qoder-permission/permission',{'mode':'unknown'})[0],400)
        self.assertEqual(qoder.state['permissionMode'],'bypassPermissions')
        self.assertEqual(self.request('/sessions/native-thread/permission',{'mode':'full-access'})[0],400)

    def test_claude_permission_changes_are_persisted_for_the_next_turn(self):
        claude=broker.Session(dict(id='claude-permission',provider='claude',cwd=folder.name,title='Claude',model='',
            busy=True,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[{'id':'pending'}],error=None))
        broker.SESSIONS[claude.state['id']]=claude
        code,payload=self.request('/sessions/claude-permission/permission',{'mode':'plan'})
        self.assertEqual(code,200)
        self.assertEqual(payload['permission']['selected'],'plan')
        self.assertEqual(json.loads(claude.path.read_text())['permissionMode'],'plan')
        self.assertEqual(claude.summary()['permission'],{'selected':'plan',
            'options':['default','acceptEdits','plan','bypassPermissions'],'scope':'next-turn'})
        # Qoder-only modes must not leak into the Claude catalog.
        self.assertEqual(self.request('/sessions/claude-permission/permission',{'mode':'dontAsk'})[0],400)
        self.assertEqual(claude.state['permissionMode'],'plan')

    def test_create_rejects_model_and_effort_outside_catalog(self):
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium'],'defaultThinking':'medium'}]
        with patch.object(broker,'codex_catalog',return_value=catalog):
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'unknown'})[0],400)
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex','thinking':'ultra'})[0],400)
    def test_create_pins_the_home_used_for_model_discovery(self):
        broker.SESSIONS.clear(); fake=FakeCodex()
        catalog=[{'id':'gpt-codex','provider':'codex','thinking':['medium'],'defaultThinking':'medium'}]
        with tempfile.TemporaryDirectory() as directory, patch.object(broker, 'ROOT', pathlib.Path(directory)):
            marker=broker.ROOT/'codex-home'; marker.write_text('/first/home')
            def discover(home):
                self.assertEqual(home, '/first/home')
                marker.write_text('/second/home')
                return catalog
            with patch.object(broker, 'codex_catalog', side_effect=discover), \
                 patch.object(broker, 'CodexAppServer', return_value=fake) as factory:
                code,payload=self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex'})
                self.assertEqual(code,200)
                session=broker.SESSIONS[payload['id']]
                self.assertEqual(session.state['codexHome'],'/first/home')
                self.assertEqual(json.loads(session.path.read_text())['codexHome'],'/first/home')
                self.assertEqual(factory.call_args.kwargs['home'],'/first/home')

    def test_model_changes_use_pinned_home_and_preserve_model_provider(self):
        self.s.state.update(codexHome='/pinned/home',provider_id='custom-provider')
        catalog=[{'id':'gpt-codex','provider':'codex','thinking':['medium','high'],'defaultThinking':'medium'}]
        with patch.object(broker, 'codex_catalog', return_value=catalog) as models, \
             patch.object(broker, 'codex_home', side_effect=AssertionError('must not follow the new default')):
            self.assertEqual(self.request('/sessions/native-thread/model',{'provider':'codex','model':'gpt-codex'})[0],200)
            self.assertEqual(self.request('/sessions/native-thread/thinking',{'level':'high'})[0],200)
        self.assertEqual([call.args for call in models.call_args_list],[('/pinned/home',),('/pinned/home',)])
        self.assertEqual(self.s.state['provider_id'],'custom-provider')

    def test_codex_catalog_discovery_runs_outside_session_lock(self):
        broker.SESSIONS.clear(); fake=FakeCodex(); observed=[]
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium'],'defaultThinking':'medium'}]
        def discover(home=None):
            def probe():
                acquired=broker.LOCK.acquire(blocking=False); observed.append(acquired)
                if acquired: broker.LOCK.release()
            worker=threading.Thread(target=probe); worker.start(); worker.join()
            return catalog
        with patch.object(broker,'codex_catalog',side_effect=discover), patch.object(broker,'CodexAppServer',side_effect=lambda *args,**kwargs:fake):
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex'})[0],200)
        self.assertEqual(observed,[True])
    def test_non_codex_mutations_skip_codex_catalog(self):
        with patch.object(broker,'codex_catalog',side_effect=AssertionError('unexpected Codex discovery')):
            code,created=self.request('/sessions',{'provider':'omp','cwd':folder.name})
            self.assertEqual(code,200)
            sid=created['id']
            self.assertEqual(self.request('/sessions/'+sid+'/model',{'provider':'openai','model':'gpt'})[0],200)
            self.assertEqual(self.request('/sessions/'+sid+'/thinking',{'level':'high'})[0],200)
    def test_model_effort_interrupt_archive_and_delete_use_native_contracts(self):
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium','ultra'],'defaultThinking':'medium'}]
        with patch.object(broker,'codex_catalog',return_value=catalog):
            self.assertEqual(self.request('/sessions/native-thread/model',{'provider':'codex','model':'gpt-codex'})[0],200)
            self.assertEqual(self.request('/sessions/native-thread/thinking',{'level':'ultra'})[0],200)
            self.assertEqual(self.request('/sessions/native-thread/thinking',{'level':'invalid'})[0],400)
        self.s.state.update(busy=True,turnId='turn-native')
        self.assertEqual(self.request('/sessions/native-thread/abort',{'turnId':'turn-native'})[0],200)
        self.assertIn(('turn/interrupt',{'threadId':'native-thread','turnId':'turn-native'}),self.fake.calls)
        self.s.state.update(busy=False,stopRequested=False)
        self.assertEqual(self.request('/sessions/native-thread/archive',{'archived':True})[0],200)
        self.assertEqual(self.request('/sessions/native-thread/archive',{'archived':False})[0],200)
        self.assertIn(('thread/archive',{'threadId':'native-thread'}),self.fake.calls)
        self.assertIn(('thread/unarchive',{'threadId':'native-thread'}),self.fake.calls)
        self.assertEqual(self.request('/sessions/native-thread/delete',{})[0],200)
        self.assertIn(('thread/delete',{'threadId':'native-thread'}),self.fake.calls)
        self.assertNotIn('native-thread',broker.SESSIONS)

class QoderHandlerContractTests(unittest.TestCase):
    CATALOGS = {
        'qoder': [
            {'id':'pro','provider':'catalog-vendor','name':'Pro','thinking':['low','high'],
             'defaultThinking':'high','_outerProvider':'trusted-route','contextWindow':131072},
            {'id':'lite','provider':'catalog-vendor','name':'Lite','thinking':['low'],'defaultThinking':'low'}],
        'qoderintl': [
            {'id':'intl-pro','provider':'intl-vendor','name':'Intl Pro','thinking':['medium'],
             'defaultThinking':'medium','_outerProvider':'intl-route'}]
    }
    def setUp(self):
        broker.TOKEN='test-token'; broker.SESSIONS.clear(); broker.QODER_MODELS={}
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def catalog(self, provider, live=False):
        return self.CATALOGS[provider]
    def session(self, provider='qoder', model='pro'):
        entry = next((item for item in self.CATALOGS[provider] if item['id'] == model), None) if model else None
        state = dict(id='qoder-contract',provider=provider,cwd=folder.name,title='Qoder',model='',thinking=None,
                     busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None)
        broker.apply_qoder_selection(state,entry,entry.get('defaultThinking') if entry else None)
        session=broker.Session(state); broker.SESSIONS[state['id']]=session
        return session

    def test_create_allows_runtime_default_and_validates_catalog_selection(self):
        with patch.object(broker,'qoder_catalog',side_effect=self.catalog) as discover:
            code,default=self.request('/sessions',{'provider':'qoder','cwd':folder.name})
            self.assertEqual(code,200); self.assertEqual((default['model'],default['thinking']),('',None))
            self.assertEqual(discover.call_count,0)
            self.assertEqual(self.request('/sessions',{'provider':'qoder','cwd':folder.name,'thinking':'high'})[0],400)
            code,selected=self.request('/sessions',{'provider':'qoder','cwd':folder.name,'model':'pro',
                                                    'thinking':'low','outerProvider':'forged'})
            self.assertEqual(code,200)
            state=broker.SESSIONS[selected['id']].state
            self.assertEqual((state['model'],state['thinking'],state['provider_id']),('pro','low','catalog-vendor'))
            self.assertEqual((state['qoderOuterProvider'],state['qoderContextWindow']),('trusted-route',131072))
            self.assertEqual(self.request('/sessions',{'provider':'qoder','cwd':folder.name,'model':'unknown'})[0],400)
            self.assertEqual(self.request('/sessions',{'provider':'qoder','cwd':folder.name,'model':'pro','thinking':'max'})[0],400)
            self.assertEqual(self.request('/sessions',{'provider':'qoderintl','cwd':folder.name,'model':'pro'})[0],400)
            code,international=self.request('/sessions',{'provider':'qoderintl','cwd':folder.name,'model':'intl-pro'})
            self.assertEqual(code,200); self.assertEqual(international['thinking'],'medium')

    def test_model_and_effort_changes_preserve_or_fall_back_then_allow_default(self):
        session=self.session()
        with patch.object(broker,'qoder_catalog',side_effect=self.catalog):
            self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'low'})[0],200)
            self.assertEqual(self.request('/sessions/qoder-contract/model',{'provider':'forged','model':'lite'})[0],200)
            self.assertEqual((session.state['model'],session.state['thinking']),('lite','low'))
            self.assertEqual(self.request('/sessions/qoder-contract/model',{'model':'pro'})[0],200)
            self.assertEqual((session.state['model'],session.state['thinking']),('pro','low'))
            self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'high'})[0],200)
            self.assertEqual(self.request('/sessions/qoder-contract/model',{'model':'lite'})[0],200)
            self.assertEqual((session.state['model'],session.state['thinking']),('lite','low'))
            self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'max'})[0],400)
            self.assertEqual(self.request('/sessions/qoder-contract/model',{'model':''})[0],200)
            self.assertEqual((session.state['model'],session.state['thinking']),('',None))
            self.assertNotIn('qoderOuterProvider',session.state)
            self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'low'})[0],400)
        session.state['busy']=True
        with patch.object(broker,'qoder_catalog',side_effect=self.catalog):
            self.assertEqual(self.request('/sessions/qoder-contract/model',{'model':'pro'})[0],400)
            self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'low'})[0],400)

    def test_default_model_request_survives_sdk_init(self):
        session=self.session(model='')
        sent=[]
        session.send=lambda value:sent.append(value)
        session.process=type('Process',(),{'poll':lambda self:None})()
        session.prompt({'text':'first','requestId':'default-first'})
        session.event({'type':'system','subtype':'init','session_id':'qoder-session','model':'resolved-default'})
        self.assertEqual(session.state['model'],'resolved-default')
        self.assertEqual(session.state['qoderRequestedModel'],'')
        self.assertEqual(session.summary()['qoderRequestedModel'],'')
        self.assertEqual(session.snapshot()['qoderRequestedModel'],'')
        session.state['busy']=False
        session.prompt({'text':'second','requestId':'default-second'})
        self.assertEqual([item['model'] for item in sent],['',''])
        session.state['busy']=False
        self.assertEqual(self.request('/sessions/qoder-contract/thinking',{'level':'low'})[0],400)

    def test_qoder_catalog_discovery_runs_outside_session_lock(self):
        observed=[]
        def discover(provider, live=False):
            acquired=broker.LOCK.acquire(blocking=False); observed.append(acquired)
            if acquired: broker.LOCK.release()
            return self.CATALOGS[provider]
        with patch.object(broker,'qoder_catalog',side_effect=discover):
            self.assertEqual(self.request('/sessions',{'provider':'qoder','cwd':folder.name,'model':'pro'})[0],200)
        self.assertEqual(observed,[True])

class DshProtocolTests(unittest.TestCase):
    OPTIONS = [
        {'id':'model','name':'Model','category':'model','type':'select','currentValue':'["deepseek-official","deepseek-v4-flash"]',
         'options':[{'group':'deepseek-official','name':'DeepSeek','options':[
             {'value':'["deepseek-official","deepseek-v4-flash"]','name':'DeepSeek-V4-Flash'},
             {'value':'["deepseek-official","deepseek-v4-pro"]','name':'DeepSeek-V4-Pro'}]}]},
        {'id':'reasoning_effort','name':'Reasoning effort','category':'thought_level','type':'select','currentValue':'high',
         'options':[{'value':'off','name':'Off'},{'value':'low','name':'Low'},{'value':'high','name':'High'},{'value':'max','name':'Max'}]}]
    def session(self):
        s = broker.Session({'id':'qd','provider':'dsh','cwd':'/tmp','title':'QD','model':'','busy':False,'archived':False,'updated':0,'revision':0,'completed':0,'messages':[],'interactions':[],'error':None})
        self.sent = []
        s.send = lambda value: self.sent.append(value)
        s.process = type('Process',(),{'poll':lambda self:None})()
        return s
    def open_session(self, s):
        s.event({'type':'acp_response','kind':'session_open','result':{'sessionId':'dsh-1','configOptions':self.OPTIONS},'error':None})
    def test_handshake_opens_session_and_applies_options(self):
        s = self.session()
        self.assertFalse(s.ready.is_set())
        self.open_session(s)
        self.assertTrue(s.ready.is_set())
        self.assertEqual(s.state['resume'],'dsh-1')
        self.assertEqual(s.state['model'],'deepseek-v4-flash')
        self.assertEqual(s.state['provider_id'],'deepseek-official')
        self.assertEqual(s.state['thinking'],'high')
        self.assertEqual(s.summary()['permission'],{'selected':'runtime-managed','options':[],'scope':'runtime-managed'})
        self.assertEqual(broker.dsh_catalog()[0]['id'],'deepseek-v4-flash')
    def test_pending_prompt_flushes_after_handshake(self):
        s = self.session()
        s.state['busy'] = True; s.state['turnId'] = 'r1'; s.state['turnState'] = 'submitting'
        s.state['requests'] = {'r1':{'id':'r1','digest':'x','status':'submitting'}}
        s.pending_prompt = ('r1','你好')
        self.assertEqual([f for f in self.sent if f.get('method')=='session/prompt'],[])
        self.open_session(s)
        frames = [f for f in self.sent if f.get('method')=='session/prompt']
        self.assertEqual(len(frames),1)
        self.assertEqual(frames[0]['params']['sessionId'],'dsh-1')
        self.assertEqual(frames[0]['params']['prompt'][0]['text'],'你好')
        self.assertEqual(s.state['requests']['r1']['status'],'submitted')
    def test_prompt_parks_until_ready(self):
        s = self.session()
        s.ready.clear()
        s.prompt({'text':'ping','requestId':'r1'})
        self.assertEqual(s.state['requests']['r1']['status'],'submitting')
        self.assertEqual([f for f in self.sent if f.get('method')=='session/prompt'],[])
    def test_open_failure_fails_parked_prompt(self):
        s = self.session()
        s.state['busy'] = True; s.state['turnId'] = 'r1'
        s.state['requests'] = {'r1':{'id':'r1','digest':'x','status':'submitting'}}
        s.pending_prompt = ('r1','ping')
        s.event({'type':'acp_response','kind':'session_open','result':None,'error':{'message':'session not found'}})
        self.assertFalse(s.state['busy'])
        self.assertEqual(s.summary()['turnState'],'failed')
        self.assertIn('session not found',s.state['error'])
        self.assertIsNone(s.pending_prompt)
    def test_updates_build_messages_tools_and_context(self):
        s = self.session(); self.open_session(s)
        s.state['busy'] = True; s.state['turnId'] = 'r1'; s.state['turnState'] = 'submitted'
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'dsh-1','update':{'sessionUpdate':'agent_thought_chunk','messageId':'m1','content':{'type':'text','text':'想一下'}}}})
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'dsh-1','update':{'sessionUpdate':'agent_message_chunk','messageId':'m1','content':{'type':'text','text':'答：'}}}})
        self.assertEqual(s.summary()['turnState'],'running')
        messages = s.snapshot()['messages']
        self.assertEqual(len(messages),1)
        parts = messages[0]['content']
        self.assertEqual([p['type'] for p in parts],['thinking','text'])
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'dsh-1','update':{'sessionUpdate':'tool_call','toolCallId':'c1','title':'bash','status':'in_progress','rawInput':{'command':'ls'}}}})
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'dsh-1','update':{'sessionUpdate':'tool_call_update','toolCallId':'c1','status':'completed','content':[{'type':'content','content':{'type':'text','text':'ok'}}]}}})
        messages = s.snapshot()['messages']
        tool_msg = next(m for m in messages if m['content'][0]['type']=='tool_use')
        self.assertEqual(tool_msg['content'][0]['tool_name'],'bash')
        result_msg = next(m for m in messages if m['role']=='tool')
        self.assertEqual(result_msg['content'][0]['tool_call_id'],'c1')
        self.assertEqual(result_msg['content'][0]['output'][0]['text'],'ok')
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'dsh-1','update':{'sessionUpdate':'usage_update','used':120,'size':1000}}})
        self.assertEqual(s.summary()['context'],{'tokens':120,'limit':1000})
    def test_updates_from_other_sessions_are_ignored(self):
        s = self.session(); self.open_session(s)
        before = s.state['revision']
        s.event({'type':'acp_notification','method':'session/update','params':{'sessionId':'other','update':{'sessionUpdate':'agent_message_chunk','messageId':'m1','content':{'type':'text','text':'x'}}}})
        self.assertEqual(s.state['revision'],before)
        self.assertEqual(s.state['messages'],[])
    def test_permission_request_maps_to_select_and_back(self):
        s = self.session(); self.open_session(s)
        s.state['busy'] = True; s.state['turnId'] = 'r1'
        s.event({'type':'acp_request','wireId':9,'method':'session/request_permission','params':{'sessionId':'dsh-1','toolCall':{'toolCallId':'c1','title':'bash','rawInput':{'command':'rm -rf build/' }},'options':[
            {'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
            {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
        interactions = s.snapshot()['interactions']
        self.assertEqual(interactions[0]['method'],'select')
        self.assertEqual(interactions[0]['options'],['Allow once','Reject'])
        # The Mac answers with the label; the bridge owes dsh the opaque optionId.
        pending = s.permission_options['acp-permission-9']
        self.assertEqual(pending['map']['Allow once'],'allow-once')
        s.send({'jsonrpc':'2.0','id':pending['wireId'],'result':{'outcome':{'outcome':'selected','optionId':pending['map']['Allow once']}}})
        response = self.sent[-1]
        self.assertEqual(response['id'],9)
        self.assertEqual(response['result']['outcome']['optionId'],'allow-once')
    def test_prompt_end_states(self):
        s = self.session(); self.open_session(s)
        s.state['busy'] = True; s.state['turnId'] = 'r1'
        s.event({'type':'acp_response','kind':'prompt:r1','result':{'stopReason':'end_turn'},'error':None})
        self.assertEqual(s.state['completed'],1)
        self.assertEqual(s.summary()['turnState'],'completed')
        s2 = self.session(); self.open_session(s2)
        s2.state['busy'] = True; s2.state['turnId'] = 'r2'; s2.state['stopRequested'] = True
        s2.event({'type':'acp_response','kind':'prompt:r2','result':{'stopReason':'cancelled'},'error':None})
        self.assertEqual(s2.summary()['turnState'],'stopped')
        self.assertEqual(s2.state['completed'],0)
        s3 = self.session(); self.open_session(s3)
        s3.state['busy'] = True; s3.state['turnId'] = 'r3'
        s3.event({'type':'acp_response','kind':'prompt:r3','result':None,'error':{'message':'Internal error: turn failed: no API key'}})
        self.assertEqual(s3.state['error'],'turn failed: no API key')
        self.assertEqual(s3.summary()['turnState'],'failed')
    def test_error_after_stop_request_reads_as_stopped(self):
        s = self.session(); self.open_session(s)
        s.state['busy'] = True; s.state['turnId'] = 'r1'; s.state['stopRequested'] = True
        s.event({'type':'acp_response','kind':'prompt:r1','result':None,'error':{'message':'Internal error: turn cancelled'}})
        self.assertIsNone(s.state['error'])
        self.assertEqual(s.summary()['turnState'],'stopped')
    def test_unknown_server_request_is_answered_not_wedged(self):
        s = self.session(); self.open_session(s)
        s.event({'type':'acp_request','wireId':33,'method':'session/other','params':{}})
        response = self.sent[-1]
        self.assertEqual(response['id'],33)
        self.assertEqual(response['error']['code'],-32601)

class DshHandlerContractTests(unittest.TestCase):
    def setUp(self):
        process_guard=patch.object(broker.subprocess,'Popen',side_effect=AssertionError('contract tests must not launch a real process'))
        process_guard.start(); self.addCleanup(process_guard.stop)
        broker.TOKEN='test-token'; broker.SESSIONS.clear(); broker.MODELS=None; broker.DSH_MODELS=None
        self.s=broker.Session(dict(id='dsh-contract',provider='dsh',cwd=folder.name,title='Test',model='',
            busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None))
        self.s.process=type('Process',(),{'poll':lambda self:None})()
        self.sent=[]; self.s.send=lambda value:self.sent.append(value)
        broker.SESSIONS['dsh-contract']=self.s
        self.s.event({'type':'acp_response','kind':'session_open','result':{'sessionId':'dsh-1','configOptions':DshProtocolTests.OPTIONS},'error':None})
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def test_answer_selected_maps_label_to_option_id(self):
        self.s.state['busy']=True; self.s.state['turnId']='r1'
        self.s.event({'type':'acp_request','wireId':9,'method':'session/request_permission','params':{'sessionId':'dsh-1','toolCall':{'toolCallId':'c1','title':'bash'},'options':[
            {'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
            {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
        code,payload=self.request('/sessions/dsh-contract/answer',{'id':'acp-permission-9','value':'Allow once'})
        self.assertEqual(code,200)
        response=self.sent[-1]
        self.assertEqual(response['result']['outcome'],{'outcome':'selected','optionId':'allow-once'})
        self.assertEqual(self.s.snapshot()['interactions'],[])
    def test_answer_cancelled_and_unknown_option(self):
        self.s.state['busy']=True; self.s.state['turnId']='r1'
        self.s.event({'type':'acp_request','wireId':10,'method':'session/request_permission','params':{'sessionId':'dsh-1','toolCall':{'toolCallId':'c2','title':'bash'},'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'}]}})
        code,_=self.request('/sessions/dsh-contract/answer',{'id':'acp-permission-10','value':'not-an-option'})
        self.assertEqual(code,400)
        code,_=self.request('/sessions/dsh-contract/answer',{'id':'acp-permission-10','cancelled':True})
        self.assertEqual(code,200)
        self.assertEqual(self.sent[-1]['result']['outcome'],{'outcome':'cancelled'})
    def test_abort_parked_prompt_settles_locally(self):
        self.s.ready.clear(); self.s.pending_prompt=('r1','ping')
        self.s.state.update(busy=True,turnId='r1',turnState='submitting',requests={'r1':{'id':'r1','digest':'x','status':'submitting'}})
        code,_=self.request('/sessions/dsh-contract/abort',{'turnId':'r1'})
        self.assertEqual(code,200)
        self.assertIsNone(self.s.pending_prompt)
        self.assertEqual(self.s.summary()['turnState'],'stopped')
        self.assertEqual([f for f in self.sent if f.get('method')=='session/cancel'],[])
    def test_abort_live_turn_notifies_cancel(self):
        self.s.state.update(busy=True,turnId='r1',turnState='running',requests={'r1':{'id':'r1','digest':'x','status':'running'}})
        code,_=self.request('/sessions/dsh-contract/abort',{'turnId':'r1'})
        self.assertEqual(code,200)
        frame=self.sent[-1]
        self.assertEqual(frame['method'],'session/cancel')
        self.assertEqual(frame['params'],{'sessionId':'dsh-1'})
        self.assertNotIn('id',frame)
    def test_model_and_thinking_actions_validate_then_send(self):
        code,_=self.request('/sessions/dsh-contract/model',{'provider':'deepseek-official','model':'deepseek-v4-pro'})
        self.assertEqual(code,200)
        frame=self.sent[-1]
        self.assertEqual(frame['method'],'session/set_config_option')
        self.assertEqual(frame['params']['configId'],'model')
        self.assertEqual(frame['params']['value'],'["deepseek-official","deepseek-v4-pro"]')
        code,_=self.request('/sessions/dsh-contract/model',{'provider':'deepseek-official','model':'not-a-model'})
        self.assertEqual(code,400)
        code,_=self.request('/sessions/dsh-contract/thinking',{'level':'max'})
        self.assertEqual(code,200)
        self.assertEqual(self.sent[-1]['params']['value'],'max')
        code,_=self.request('/sessions/dsh-contract/thinking',{'level':'xhigh'})
        self.assertEqual(code,400)
    def test_combined_catalog_survives_omp_failure(self):
        def fail(*args,**kwargs): raise OSError('omp not installed')
        with patch.object(broker.subprocess,'run',side_effect=fail):
            code,payload=self.request('/models')
        self.assertEqual(code,200)
        self.assertEqual(payload['models'][0]['provider'],'deepseek-official')
        # Survivors still say which runtime owns them, so the picker can go on filtering.
        self.assertEqual({e['agent'] for e in payload['models']},{'dsh'})
    def test_combined_catalog_bounds_each_qoder_region(self):
        calls=[]
        def discover(provider, live=False, timeout=60):
            calls.append((provider,timeout))
            if provider=='qoder': raise subprocess.TimeoutExpired(provider,timeout)
            return [{'id':'intl-pro','provider':'intl-vendor','name':'Intl Pro'}]
        with patch.object(broker,'model_catalog',return_value=[]), \
             patch.object(broker,'qoder_catalog',side_effect=discover), \
             patch.object(broker,'codex_catalog',return_value=[]):
            code,payload=self.request('/models')
        self.assertEqual(code,200)
        self.assertEqual(calls,[('qoder',10),('qoderintl',10)])
        self.assertIn(('qoderintl','intl-pro'),[(e['agent'],e['id']) for e in payload['models']])
    def test_combined_catalog_tags_each_runtime(self):
        broker.MODELS=[{'provider':'openai-codex','id':'gpt-5.4-mini','name':'GPT-5.4 mini','selector':'openai-codex/gpt-5.4-mini'}]
        codex=[{'provider':'codex','id':'gpt-codex','thinking':['medium'],'defaultThinking':'medium'}]
        with patch.object(broker,'codex_catalog',return_value=codex):
            code,payload=self.request('/models')
        self.assertEqual(code,200)
        self.assertCountEqual([(e['agent'],e['id']) for e in payload['models']],
                              [('omp','gpt-5.4-mini'),('dsh','deepseek-v4-flash'),('dsh','deepseek-v4-pro'),('codex','gpt-codex')])
        self.assertNotIn('agent',codex[0])
        # Tagging builds new dicts; the cached CLI output stays as omp emitted it.
        self.assertNotIn('agent',broker.MODELS[0])

class HandlerContractTests(unittest.TestCase):
    def setUp(self):
        process_guard=patch.object(broker.subprocess,'Popen',side_effect=AssertionError('contract tests must not launch a real process'))
        process_guard.start(); self.addCleanup(process_guard.stop)
        broker.TOKEN='test-token'; broker.SESSIONS.clear(); broker.MODELS=None
        self.s=broker.Session(dict(id='contract',provider='omp',cwd=folder.name,title='Test',model='',
            busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None))
        self.s.process=type('Process',(),{'poll':lambda self:None})()
        self.sent=[]; self.s.send=lambda value:self.sent.append(value)
        broker.SESSIONS['contract']=self.s
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def prompt(self,key='one'):
        return self.request('/sessions/contract/prompt',{'text':'中文指令','requestId':key})
    def plan(self, text='## Plan\nDo the scoped work.'):
        self.s.state['provider']='claude'
        self.s.event({'type':'interaction','id':'plan-tool','name':'ExitPlanMode','input':{'plan':text}})
        return self.s.state['interactions'][0]['planReview']['revision']
    def test_plan_defer_resume_and_approval_are_explicit(self):
        revision=self.plan(); base={'id':'plan-tool','planRevision':revision}
        for decision,status in [('defer','deferred'),('resume','awaiting_review')]:
            code,_=self.request('/sessions/contract/answer',{**base,'decision':decision})
            self.assertEqual(code,200); self.assertEqual(self.sent,[])
            self.assertEqual(self.s.snapshot()['interactions'][0]['planReview']['status'],status)
            self.assertEqual(json.loads(self.s.path.read_text())['interactions'][0]['planReview']['status'],status)
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'approve'})
        self.assertEqual(code,200); self.assertEqual(self.sent,[{'type':'answer','id':'plan-tool','allow':True,'feedback':''}])
        self.assertEqual(self.s.snapshot()['interactions'],[])
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'approve'})
        self.assertEqual(code,409); self.assertEqual(len(self.sent),1)
    def test_plan_revision_conflict_and_cancel_do_not_send(self):
        old=self.plan('old'); current=self.plan('new')
        self.assertNotEqual(old,current)
        code,_=self.request('/sessions/contract/answer',{'id':'plan-tool','planRevision':old,'decision':'approve'})
        self.assertEqual(code,409); self.assertEqual(self.sent,[])
        code,_=self.request('/sessions/contract/answer',{'id':'plan-tool','allow':True})
        self.assertEqual(code,409); self.assertEqual(self.sent,[])
        self.s.event({'type':'interaction_cancel','id':'plan-tool'})
        code,_=self.request('/sessions/contract/answer',{'id':'plan-tool','planRevision':current,'decision':'approve'})
        self.assertEqual(code,409); self.assertEqual(self.sent,[])
    def test_plan_changes_missing_content_and_wire_failure(self):
        revision=self.plan(''); base={'id':'plan-tool','planRevision':revision}
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'approve'})
        self.assertEqual(code,400); self.assertEqual(self.sent,[])
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'request_changes','feedback':'  '})
        self.assertEqual(code,400)
        with patch.object(self.s,'send',side_effect=BrokenPipeError('fixture disconnected')):
            code,_=self.request('/sessions/contract/answer',{**base,'decision':'request_changes','feedback':'补充回滚方案'})
        self.assertEqual(code,400); self.assertEqual(len(self.s.state['interactions']),1)
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'request_changes','feedback':'补充回滚方案'})
        self.assertEqual(code,200); self.assertEqual(self.sent[-1]['feedback'],'补充回滚方案'); self.assertFalse(self.sent[-1]['allow'])
        self.assertEqual(self.s.state['planReviewHistory'][-1]['status'],'request_changes')
    def test_deferred_plan_cannot_be_approved_by_stale_client(self):
        revision=self.plan(); base={'id':'plan-tool','planRevision':revision}
        self.request('/sessions/contract/answer',{**base,'decision':'defer'})
        code,_=self.request('/sessions/contract/answer',{**base,'decision':'approve'})
        self.assertEqual(code,409); self.assertEqual(self.sent,[])

    def test_models_unwraps_omp_json_and_tags_the_runtime(self):
        # 18.1.16 answers ModelsJson, not a bare list, and one malformed entry must
        # not take the whole catalog down with it.
        broker.DSH_MODELS=[]
        broker.MODELS={'models':[{'provider':'aone','id':'deepseek-v4-pro','selector':'aone/deepseek-v4-pro',
                                 'name':'DeepSeek V4 Pro · Aone','contextWindow':1000000,'thinking':['low','high','max']},'not-a-model']}
        code,payload=self.request('/models')
        self.assertEqual(code,200)
        self.assertEqual([(e['agent'],e['id']) for e in payload['models']],[('omp','deepseek-v4-pro')])
        self.assertEqual(payload['models'][0]['thinking'],['low','high','max'])
        self.assertEqual(payload['models'][0]['selector'],'aone/deepseek-v4-pro')
    def test_http_window_and_delta_parameters(self):
        for i in range(60):
            self.s.upsert({'role':'user','content':'question'},'u'+str(i))
            self.s.upsert({'role':'assistant','content':'answer'},'a'+str(i))
        self.s.touch()
        code,first=self.request('/sessions/contract?turns=50')
        self.assertEqual(code,200);self.assertEqual(len(first['messages']),100)
        h=first['history']
        code,page=self.request('/sessions/contract?before=%d&epoch=%s&turns=50' % (h['start'],h['epoch']))
        self.assertEqual(code,200);self.assertEqual(len(page['messages']),20)
        self.s.upsert({'role':'assistant','content':'changed'},'a59');self.s.touch()
        code,delta=self.request('/sessions/contract?start=%d&epoch=%s&revision=%d' % (h['start'],h['epoch'],first['revision']))
        self.assertEqual(code,200);self.assertEqual(delta['history']['indices'],[119])
        self.assertEqual(len(delta['messages']),1)

    def test_unchanged_snapshot_skips_history_copy_but_expires_approvals(self):
        self.s.state['messages']=[{'id':'history','role':'assistant','content':[{'type':'text','text':'历史'}]}]
        with patch.object(broker.copy,'deepcopy',side_effect=AssertionError('unchanged history must not be copied')):
            self.assertEqual(self.request('/sessions/contract?revision=0'),(200,{'unchanged':True}))
        self.s.state['interactions']=[{'id':'expired','expires':1}]
        code,value=self.request('/sessions/contract?revision=0')
        self.assertEqual(code,200); self.assertEqual(value['revision'],1)
        self.assertEqual(value['interactions'],[])
        self.assertEqual(value['messages'],self.s.state['messages'])
        value['messages'].clear()
        self.assertEqual(len(self.s.state['messages']),1,'changed snapshots must remain detached')

    def test_steer_during_turn_and_echo_are_idempotent(self):
        self.prompt()
        self.s.event({'type':'agent_start'})
        body={'text':'改为只读分析','requestId':'guidance'}
        self.assertTrue(self.s.summary()['steer'])
        self.assertEqual(self.request('/sessions/contract/steer',body)[1]['status'],'submitted')
        self.assertEqual(self.s.state['turnId'],'one')
        self.assertTrue(self.s.state['busy'])
        self.assertEqual(self.sent[-1],dict(type='steer',id='guidance',message='改为只读分析'))
        self.s.event(dict(type='response',command='steer',id='guidance',success=True))
        self.assertEqual(self.request('/sessions/contract/steer',body)[1]['status'],'accepted')
        self.assertEqual(len([x for x in self.sent if x['type']=='steer']),1)
        for kind in ['message_start','message_update','message_end']:
            self.s.event(dict(type=kind,message=dict(role='user',timestamp=123,content=[dict(type='text',text=body['text'])])))
        self.assertEqual([m['id'] for m in self.s.snapshot()['messages']],['guidance'])
        self.assertEqual(self.request('/sessions/contract/requests/guidance')[1]['status'],'consumed')
        # A late acknowledgement cannot regress consumed to accepted.
        self.s.event(dict(type='response',command='steer',id='guidance',success=True))
        self.assertEqual(self.request('/sessions/contract/requests/guidance')[1]['status'],'consumed')
        self.s.event(dict(type='agent_end'))
        self.assertEqual(self.request('/sessions/contract/requests/one')[1]['status'],'completed')
        self.assertEqual(self.request('/sessions/contract/requests/guidance')[1]['status'],'consumed')

    def test_repeated_identical_steers_have_distinct_echoes(self):
        self.prompt()
        for n in range(2):
            self.request('/sessions/contract/steer',dict(text='补充',requestId='s'+str(n)))
        for n in range(2):
            self.s.event(dict(type='message_end',message=dict(role='user',timestamp=n,content=[dict(type='text',text='补充')])))
        self.assertEqual([m['id'] for m in self.s.snapshot()['messages']],['s0','s1'])

    def test_steer_races_completion_and_rejection_preserves_active_turn(self):
        self.prompt(); self.s.event(dict(type='agent_end'))
        self.assertEqual(self.request('/sessions/contract/steer',dict(text='补充',requestId='two'))[0],200)
        self.assertEqual(self.sent[-1]['type'],'prompt')
        self.assertEqual(self.s.state['turnId'],'two')
        self.request('/sessions/contract/steer',dict(text='另一个',requestId='three'))
        self.s.event(dict(type='response',command='steer',id='three',success=False,error='rejected'))
        self.assertEqual(self.request('/sessions/contract/requests/three')[1]['status'],'failed')
        self.assertTrue(self.s.state['busy']); self.assertIsNone(self.s.state['error'])
        self.s.state['provider']='qoder'
        self.assertFalse(self.s.summary()['steer'])
        self.assertEqual(self.request('/sessions/contract/steer',dict(text='补充',requestId='four'))[0],400)

    def test_unconsumed_steer_is_not_claimed_complete_or_replayed(self):
        self.prompt()
        body=dict(text='补充',requestId='steering')
        self.request('/sessions/contract/steer',body)
        self.s.event(dict(type='response',command='steer',id='steering',success=True))
        self.s.state['cancelled']=True; self.s.event(dict(type='agent_end'))
        self.assertEqual(self.request('/sessions/contract/requests/steering')[1]['status'],'unknown')
        self.request('/sessions/contract/steer',body)
        self.assertEqual(len([x for x in self.sent if x['type']=='steer']),1)

    def test_duplicate_prompt_after_completion_and_reload_is_not_replayed(self):
        self.assertEqual(self.prompt()[0],200)
        self.s.event({'type':'agent_end'})
        self.assertEqual(self.prompt()[1]['status'],'completed')
        self.assertEqual(len([x for x in self.sent if x['type']=='prompt']),1)
        broker.load()
        self.assertEqual(self.prompt()[1]['status'],'completed')
        self.assertEqual(len([x for x in self.sent if x['type']=='prompt']),1)
    def test_pipe_submission_is_not_runtime_acceptance_and_ledger_is_private(self):
        self.assertEqual(self.prompt()[1]['status'],'submitted')
        self.assertNotIn('requests',self.s.snapshot())
        self.s.event({'type':'response','command':'prompt','id':'one','success':True})
        self.assertEqual(self.request('/sessions/contract/requests/one')[1]['status'],'accepted')
        self.s.event({'type':'agent_start'})
        self.assertEqual(self.s.summary()['turnState'],'running')
    def test_qoder_stop_ack_requires_turn_match_and_iterator_termination(self):
        self.s.state['provider']='qoder'; self.prompt()
        self.s.event({'type':'stop_ack','turnId':'other'})
        self.assertFalse(self.s.state['stopAcknowledged'])
        self.s.event({'type':'stop_ack','turnId':'one'})
        self.assertTrue(self.s.state['busy']); self.assertFalse(self.s.state['cancelled'])
        self.s.event({'type':'agent_end'})
        self.assertEqual(self.s.summary()['turnState'],'stopped')
    def test_compact_write_failure_clears_inflight_command(self):
        def fail(value): raise OSError('broken pipe')
        self.s.send=fail
        self.assertEqual(self.request('/sessions/contract/command',{'name':'compact'})[0],400)
        self.assertIsNone(self.s.command_id)
        self.assertEqual(self.s.snapshot()['commandResult']['status'],'failed')
    def test_saved_v1_command_result_is_readable_by_v2_client(self):
        old=dict(self.s.state,commandResult='nothing to compact')
        restored=broker.Session(old)
        self.assertEqual(restored.snapshot()['commandResult']['status'],'unknown')
        self.assertIn('nothing to compact',restored.snapshot()['commandResult']['error'])
    def test_reused_id_with_changed_text_is_rejected(self):
        self.prompt()
        self.assertEqual(self.request('/sessions/contract/prompt',{'text':'different','requestId':'one'})[0],400)
    def test_lost_write_or_service_restart_is_unknown_and_never_replayed(self):
        def fail(value): raise OSError('stdin outcome unknown')
        self.s.send=fail
        self.assertEqual(self.prompt()[1]['status'],'unknown')
        self.s.send=lambda value:self.fail('must not replay')
        self.assertEqual(self.prompt()[1]['status'],'unknown')
        self.s.state['requests']['one']['status']='accepted'; self.s.state['turnState']='accepted'; self.s.persist()
        broker.load()
        self.assertEqual(self.prompt()[1]['status'],'unknown')
    def test_stop_waits_for_terminal_event_and_targets_the_original_turn(self):
        self.prompt()
        self.assertEqual(self.request('/sessions/contract/abort',{'turnId':'other'})[0],400)
        self.assertEqual(self.request('/sessions/contract/abort',{'turnId':'one'})[0],200)
        self.assertTrue(self.s.state['busy']); self.assertFalse(self.s.state['cancelled'])
        self.request('/sessions/contract/abort',{'turnId':'one'})
        self.assertEqual(len([x for x in self.sent if x['type']=='abort']),1)
        self.s.event({'type':'message_end','message':{'role':'assistant','timestamp':1,'stopReason':'aborted','content':[]}})
        self.assertTrue(self.s.state['busy'])
        self.s.event({'type':'agent_end'})
        self.assertEqual(self.s.summary()['turnState'],'stopped')
        self.prompt('two')
        self.assertEqual(self.request('/sessions/contract/abort',{'turnId':'one'})[0],400)
    def test_natural_completion_after_stop_request_is_not_false_stopped(self):
        self.prompt(); self.request('/sessions/contract/abort',{'turnId':'one'})
        self.s.event({'type':'agent_end'})
        self.assertEqual(self.s.summary()['turnState'],'completed')
    def test_discovery_does_not_block_other_requests(self):
        responses=[]
        def models(*args,**kwargs):
            worker=threading.Thread(target=lambda:responses.append(self.request('/health')))
            worker.start(); worker.join(timeout=1)
            self.assertFalse(worker.is_alive(),'model discovery held the session lock')
            return type('Result',(),{'returncode':0,'stdout':'[]'})()
        with patch.object(broker.subprocess,'run',side_effect=models):
            self.assertEqual(self.request('/models')[0],200)
        self.assertEqual(responses[0][0],200)
    def test_compact_rejects_arguments_and_exposes_async_failure(self):
        self.assertEqual(self.request('/sessions/contract/command',{'name':'compact','arguments':'soft'})[0],400)
        self.assertEqual(self.request('/sessions/contract/command',{'name':'compact'})[0],200)
        command=self.s.command_id
        self.assertEqual(self.request('/sessions/contract/command',{'name':'compact'})[0],400)
        self.s.event({'type':'response','id':command,'success':False,'error':'nothing to compact'})
        self.assertEqual(self.s.snapshot()['commandResult']['error'],'nothing to compact')
        self.assertIsNone(self.s.state['error'])

class ClaudeSubagentTests(unittest.TestCase):
    def setUp(self):
        process_guard=patch.object(broker.subprocess,'Popen',side_effect=AssertionError('contract tests must not launch a real process'))
        process_guard.start(); self.addCleanup(process_guard.stop)
        # The write debounce never fires by itself here; tests fire it explicitly.
        timer=patch.object(broker.threading,'Timer'); self.timer=timer.start(); self.addCleanup(timer.stop)
        broker.TOKEN='test-token'; broker.SESSIONS.clear()
        self.s=self.claude('claude-'+self._testMethodName)
    def claude(self, identity):
        s=broker.Session(dict(id=identity,provider='claude',cwd=folder.name,title='Claude',model='',
            busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None))
        s.process=type('Process',(),{'poll':lambda self:None})()
        s.sent=[]; s.send=lambda value:s.sent.append(value)
        broker.SESSIONS[identity]=s
        s.prompt({'text':'派子 Agent','requestId':'turn-1'}); s.event({'type':'agent_start'})
        return s
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def path(self,key): return '/sessions/'+self.s.state['id']+'/subagents/'+key
    def task(self,subtype,task_id,s=None,**fields): (s or self.s).event({'type':'system','subtype':subtype,'task_id':task_id,**fields})
    def started(self,task_id,tool,s=None,**fields):
        self.task('task_started',task_id,s,**{'tool_use_id':tool,'task_type':'local_agent','description':'子任务 '+task_id,**fields})
    def spawn(self,tool,**fields):
        self.s.event({'type':'assistant','uuid':'call-'+tool,'parent_tool_use_id':None,'message':{'role':'assistant','content':[
            {'type':'tool_use','id':tool,'name':'Agent','input':{'description':'查找调用点','prompt':'在仓库中查找\n细节','subagent_type':'Explore',**fields}}]}})
    def child(self,tool,identity,content,role='assistant',s=None):
        (s or self.s).event({'type':role,'uuid':identity,'parent_tool_use_id':tool,'message':{'role':role,'content':content}})
    def result(self,tool,content,error=False):
        self.s.event({'type':'user','uuid':'result-'+tool,'parent_tool_use_id':None,'message':{'role':'user','content':[
            {'type':'tool_result','tool_use_id':tool,'content':content,'is_error':error}]}})
    def roster(self,s=None): return {x['id']:x for x in (s or self.s).snapshot()['subagents']}

    def test_child_messages_first_make_a_provisional_entry_that_task_started_adopts(self):
        self.spawn('toolu_A')
        revision=self.s.state['revision']
        self.child('toolu_A','c1',[{'type':'tool_use','id':'grep-1','name':'Grep','input':{'pattern':'main'}}])
        # Registering the child is a roster change, so the session revision moves once.
        self.assertEqual(self.s.state['revision'],revision+1)
        entry=self.roster()['toolu_A']
        self.assertEqual(list(entry),list(broker.SUBAGENT_KEYS))
        self.assertEqual((entry['kind'],entry['taskId'],entry['toolUseIds'],entry['turnId'],entry['description'],entry['subagentType'],
                          entry['status'],entry['background'],entry['usage'],entry['endedAt'],entry['messageCount'],entry['canStop']),
                         ('claude',None,['toolu_A'],'turn-1','查找调用点','Explore','running',None,None,None,1,False))
        # UTC with milliseconds and Z, the form KimiTask's date parser reads.
        self.assertEqual(len(entry['startedAt']),24)
        broker.datetime.datetime.strptime(entry['startedAt'],'%Y-%m-%dT%H:%M:%S.%fZ')
        self.started('task-A','toolu_A',subagent_type='Explore',is_backgrounded=True)
        entry=self.roster()['toolu_A']
        self.assertEqual((entry['id'],entry['taskId'],entry['description'],entry['background'],entry['canStop']),
                         ('toolu_A','task-A','子任务 task-A',True,True))
        self.assertEqual(len(self.s.state['subagentRoster']),1)
        for key in ('toolu_A','task-A'):
            code,page=self.request(self.path(key))
            self.assertEqual((code,page['entry']['id'],[m['id'] for m in page['messages']]),(200,'toolu_A',['c1']))
        self.assertEqual(page['messages'][0]['content'],[{'type':'tool_use','tool_call_id':'grep-1','tool_name':'Grep','input':{'pattern':'main'}}])
        # Without a description the first line of the prompt names the child, and
        # an explicit background flag is kept until a task event says otherwise.
        self.spawn('toolu_B',description='',run_in_background=False)
        self.child('toolu_B','b1','开始')
        entry=self.roster()['toolu_B']
        self.assertEqual((entry['description'],entry['background']),('在仓库中查找',False))

    def test_task_started_first_routes_child_messages_through_the_tool_alias(self):
        self.started('task-B','toolu_B')
        self.child('toolu_B','c1','第一步'); self.child('toolu_B','c1','第一步（改）')
        self.child('toolu_B','c2',[{'type':'tool_result','tool_use_id':'grep','content':'ok'}],role='user')
        page=self.s.subagent_page('toolu_B')
        self.assertEqual((page['entry']['id'],page['entry']['toolUseIds'],page['total']),('task-B',['toolu_B'],2))
        self.assertEqual(page['messages'][0]['content'][0]['text'],'第一步（改）')
        self.assertEqual(page['messages'][1]['content'][0],{'type':'tool_result','tool_call_id':'grep','output':'ok','is_error':False})
        # Synthetic context inside a child is marked as on the main thread.
        self.s.event({'type':'user','uuid':'c3','isSynthetic':True,'parent_tool_use_id':'toolu_B','message':{'role':'user','content':'context'}})
        self.assertEqual(self.s.subagent_page('task-B')['messages'][2]['content'][0]['source'],{'kind':'runtime_context','provider':'claude'})

    def test_task_events_map_statuses_and_finished_entries_never_revive(self):
        self.started('task-C','toolu_C')
        for patch_status,status in (('pending','queued'),('running','running'),('paused','running')):
            self.task('task_updated','task-C',patch={'status':patch_status})
            self.assertEqual(self.roster()['task-C']['status'],status)
        self.task('task_progress','task-C',tool_use_id='toolu_C',description='子任务 task-C',
                  usage={'total_tokens':1200,'tool_uses':3,'duration_ms':4500},last_tool_name='Grep')
        entry=self.roster()['task-C']
        self.assertEqual((entry['usage'],entry['lastToolName']),({'totalTokens':1200,'toolUses':3,'durationMs':4500},'Grep'))
        self.task('task_notification','task-C',tool_use_id='toolu_C',status='completed',summary='找到 3 处调用',output_file='/tmp/out',
                  usage={'total_tokens':1500,'tool_uses':4,'duration_ms':6000})
        done=self.roster()['task-C']
        self.assertEqual((done['status'],done['summary'],done['usage']['totalTokens'],done['canStop']),('completed','找到 3 处调用',1500,False))
        self.assertTrue(done['endedAt'])
        revision=self.s.state['revision']
        self.started('task-C','toolu_C'); self.task('task_progress','task-C',usage={'total_tokens':9})
        self.task('task_updated','task-C',patch={'status':'running'})
        self.assertEqual((self.roster()['task-C'],self.s.state['revision']),(done,revision))
        # Child messages that arrive after the end still land in the transcript.
        self.child('toolu_C','late','最后的回复')
        page=self.s.subagent_page('task-C')
        self.assertEqual((page['entry']['status'],page['messages'][-1]['id']),('completed','late'))
        # killed reads as stopped with the runtime's end time; failed keeps its error.
        self.started('task-D','toolu_D'); self.task('task_updated','task-D',patch={'status':'killed','end_time':1760765409123})
        self.assertEqual((self.roster()['task-D']['status'],self.roster()['task-D']['endedAt']),('stopped','2025-10-18T05:30:09.123Z'))
        self.started('task-E','toolu_E'); self.task('task_updated','task-E',patch={'status':'failed','error':'API 超时'})
        self.assertEqual((self.roster()['task-E']['status'],self.roster()['task-E']['error']),('failed','API 超时'))

    def test_notification_before_started_creates_a_finished_entry(self):
        self.spawn('toolu_F')
        self.task('task_notification','task-F',tool_use_id='toolu_F',status='failed',summary='权限不足',output_file='/tmp/x')
        entry=self.roster()['task-F']
        self.assertEqual((entry['status'],entry['description'],entry['summary']),('failed','查找调用点','权限不足'))
        self.started('task-F','toolu_F')
        self.assertEqual(self.roster()['task-F']['status'],'failed')

    def test_only_subagent_tasks_enter_the_roster(self):
        self.spawn('toolu_G')
        revision=self.s.state['revision']
        self.task('task_started','bash-1',tool_use_id='toolu_bash',task_type='local_bash',description='npm test')
        self.task('task_started','ambient-1',tool_use_id='toolu_G',task_type='local_agent',description='watch',ambient=True)
        self.task('task_started','hidden-1',task_type='local_agent',description='memory',skip_transcript=True)
        self.task('task_started','orphan-1',tool_use_id='toolu_unknown',description='no type, no Agent call')
        self.task('task_notification','bash-1',tool_use_id='toolu_bash',status='completed',summary='done',output_file='/tmp/x')
        # An ignored task stays ignored, even when it names a real Agent call.
        self.task('task_progress','ambient-1',tool_use_id='toolu_G',description='watch',usage={'total_tokens':1,'tool_uses':0,'duration_ms':1})
        self.s.event({'type':'system','subtype':'background_tasks_changed','tasks':[{'task_id':'x','task_type':'local_agent','description':'d'}]})
        self.assertEqual((self.s.state['revision'],self.s.snapshot()['subagents']),(revision,[]))
        # Without a task type, a task whose tool_use is an Agent call is a subagent.
        self.task('task_started','task-G',tool_use_id='toolu_G',description='旧版 CLI')
        self.assertEqual(list(self.roster()),['task-G'])

    def test_main_tool_result_ends_only_entries_no_task_event_described(self):
        self.spawn('toolu_H'); self.child('toolu_H','h1','工作中')
        self.result('toolu_H',[{'type':'text','text':'报告：完成'}])
        self.assertEqual((self.roster()['toolu_H']['status'],self.roster()['toolu_H']['summary']),('completed','报告：完成'))
        self.assertTrue(self.s.subagent_path('toolu_H').exists())
        self.spawn('toolu_I'); self.child('toolu_I','i1','工作中')
        self.result('toolu_I','Agent 失败',error=True)
        self.assertEqual((self.roster()['toolu_I']['status'],self.roster()['toolu_I']['error']),('failed','Agent 失败'))
        # A background child answers its tool call at once and keeps running.
        self.started('task-J','toolu_J'); self.result('toolu_J','Async agent launched')
        self.assertEqual(self.roster()['task-J']['status'],'running')

    def test_turn_end_and_worker_exit_settle_running_children(self):
        self.started('task-K','toolu_K'); self.child('toolu_K','k1','进行中')
        self.assertFalse(self.s.subagent_path('task-K').exists())
        self.s.event({'type':'agent_end'})
        entry=self.s.subagent_page('task-K')['entry']
        self.assertEqual((entry['status'],entry['canStop']),('unknown',False)); self.assertTrue(entry['endedAt'])
        self.assertEqual([m['id'] for m in json.loads(self.s.subagent_path('task-K').read_text())['messages']],['k1'])
        # A turn the user stopped settles its children as stopped.
        stopped=self.claude(self.s.state['id']+'-stopped')
        self.started('task-L','toolu_L',s=stopped)
        stopped.event({'type':'stop_ack','turnId':'turn-1'}); stopped.event({'type':'agent_end'})
        self.assertEqual(stopped.subagent_page('task-L')['entry']['status'],'stopped')
        # A worker that exits mid-turn leaves its children unknown.
        crashed=self.claude(self.s.state['id']+'-crashed')
        self.started('task-M','toolu_M',s=crashed)
        crashed.process=type('Process',(),{'stdout':iter(()),'poll':lambda self:0})()
        crashed.read()
        self.assertEqual((crashed.state['busy'],crashed.subagent_page('task-M')['entry']['status']),(False,'unknown'))

    def test_approvals_from_children_are_labelled_and_patched_late(self):
        # agentID equal to the task id resolves once the task registers.
        self.s.event({'type':'interaction','id':'child-tool-x','name':'Bash','input':{'command':'ls'},'agentId':'agent-x'})
        x=self.s.state['interactions'][-1]
        self.assertNotIn('agentId',x)
        self.assertEqual(x['subagent'],{'id':None,'agentId':'agent-x','title':None,'type':None})
        revision=self.s.state['revision']
        self.started('agent-x','toolu_X',subagent_type='Explore')
        self.assertEqual(x['subagent'],{'id':'agent-x','agentId':'agent-x','title':'子任务 agent-x','type':'Explore'})
        self.assertGreater(self.s.state['revision'],revision)
        # An agentID unlike every task id resolves by the transcript that holds the
        # approved tool call; later approvals of that agent resolve at once.
        self.started('task-Y','toolu_Y')
        self.s.event({'type':'interaction','id':'child-tool-y','name':'Bash','input':{},'agentId':'agent-y'})
        y=self.s.state['interactions'][-1]; self.assertIsNone(y['subagent']['id'])
        revision=self.s.state['revision']
        self.child('toolu_Y','y1',[{'type':'tool_use','id':'child-tool-y','name':'Bash','input':{}}])
        self.assertEqual(y['subagent'],{'id':'task-Y','agentId':'agent-y','title':'子任务 task-Y','type':None})
        self.assertEqual(self.s.state['revision'],revision+1)
        self.s.event({'type':'interaction','id':'child-tool-y2','name':'Bash','input':{},'agentId':'agent-y'})
        self.assertEqual(self.s.state['interactions'][-1]['subagent']['id'],'task-Y')
        # A later description reaches the label as well.
        self.task('task_updated','task-Y',patch={'description':'改名后的子任务'})
        self.assertEqual(y['subagent']['title'],'改名后的子任务')
        # Main-thread approvals keep their old shape.
        self.s.event({'type':'interaction','id':'main-tool','name':'Bash','input':{},'agentId':None})
        self.assertEqual(self.s.state['interactions'][-1],{'type':'interaction','id':'main-tool','name':'Bash','input':{}})

    def test_snapshot_lists_the_live_roster_and_summary_counts_running(self):
        for task_id in ('old','done','run'): self.started(task_id,'toolu_'+task_id)
        for task_id in ('old','done'): self.task('task_notification',task_id,status='completed',summary='完成',output_file='')
        # Finished children of an earlier turn drop out; running ones never do.
        for task_id in ('old','run'): self.s.subagent_entries[task_id]['turnId']='turn-0'
        full=self.s.snapshot(); page=self.s.snapshot(turns='50')
        self.assertEqual([x['id'] for x in full['subagents']],['done','run'])
        self.assertEqual(page['subagents'],full['subagents'])
        self.assertEqual(self.s.summary()['runningSubagents'],1)
        for value in (full,page): self.assertNotIn('subagentRoster',value)
        self.assertEqual(len(self.s.state['subagentRoster']),3)
        self.started('next','toolu_next')
        delta=self.s.snapshot(revision=str(page['revision']),start=str(page['history']['start']),epoch=page['history']['epoch'])
        self.assertEqual([x['id'] for x in delta['subagents']],['done','run','next'])
        self.assertNotIn('subagentRoster',delta)
        # A pending approval keeps naming its child, from any turn.
        self.s.event({'type':'interaction','id':'late','name':'Bash','input':{},'agentId':'old'})
        self.assertEqual([x['id'] for x in self.s.snapshot()['subagents']],['old','done','run','next'])

    def test_snapshot_caps_the_live_list_in_start_order(self):
        for i in range(40): self.started('task-%02d' % i,'toolu-%02d' % i)
        self.assertEqual([x['id'] for x in self.s.snapshot()['subagents']],['task-%02d' % i for i in range(8,40)])
        self.assertEqual(self.s.summary()['runningSubagents'],40)
        self.s.event({'type':'interaction','id':'child','name':'Bash','input':{},'agentId':'task-00'})
        self.assertEqual([x['id'] for x in self.s.snapshot()['subagents']],['task-00']+['task-%02d' % i for i in range(9,40)])

    def test_sessions_without_subagents_report_empty_lists(self):
        codex,_=CodexProtocolTests().session('codex-plain')
        omp=broker.Session(dict(id='omp-plain',provider='omp',cwd=folder.name,title='OMP',model='',
            busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None))
        for s in (codex,omp):
            self.assertEqual((s.snapshot()['subagents'],s.snapshot(turns='50')['subagents'],s.summary()['runningSubagents']),([],[],0))
            self.assertNotIn('subagentRoster',s.state)

    def test_transcript_route_serves_window_delta_unchanged_and_older_pages(self):
        self.started('task-T','toolu_T')
        for i in range(250): self.child('toolu_T','m%d' % i,'消息 %d' % i)
        revision=self.s.state['revision']
        code,full=self.request(self.path('toolu_T'))
        self.assertEqual(set(full),{'entry','epoch','revision','total','truncated','start','messages'})
        self.assertEqual((code,full['total'],full['truncated'],full['start'],len(full['messages']),full['messages'][0]['id']),(200,250,0,50,200,'m50'))
        self.assertEqual((full['entry']['id'],full['entry']['revision'],full['entry']['messageCount']),('task-T',full['revision'],250))
        query='?epoch=%s&revision=%d' % (full['epoch'],full['revision'])
        self.assertEqual(self.request(self.path('task-T')+query),(200,{'unchanged':True}))
        self.child('toolu_T','m10','消息 10（改）'); self.child('toolu_T','m250','消息 250')
        code,delta=self.request(self.path('task-T')+query)
        self.assertEqual(set(delta),{'entry','epoch','revision','total','truncated','changes'})
        self.assertEqual(([c['index'] for c in delta['changes']],delta['total'],delta['revision']),([10,250],251,full['revision']+2))
        self.assertEqual(delta['changes'][0]['message']['content'][0]['text'],'消息 10（改）')
        # Entry changes reach a follower as a delta without messages.
        self.task('task_progress','task-T',usage={'total_tokens':10,'tool_uses':1,'duration_ms':5})
        code,change=self.request(self.path('task-T')+'?epoch=%s&revision=%d' % (delta['epoch'],delta['revision']))
        self.assertEqual((change['changes'],change['entry']['usage']['totalTokens']),([],10))
        code,older=self.request(self.path('task-T')+'?epoch=%s&before=50&limit=30' % full['epoch'])
        self.assertEqual((older['start'],[m['id'] for m in older['messages']]),(20,['m%d' % i for i in range(20,50)]))
        self.assertEqual(set(older),{'entry','epoch','revision','total','truncated','start','messages'})
        code,default=self.request(self.path('task-T')+'?epoch=%s&before=150' % full['epoch'])
        self.assertEqual((default['start'],len(default['messages'])),(50,100))
        for bad in ('&before=50&limit=201','&before=50&limit=0','&before=252','&before=x'):
            self.assertEqual(self.request(self.path('task-T')+'?epoch='+full['epoch']+bad)[0],400)
        # A stale epoch answers an older page as the main history route does.
        stale=self.request(self.path('task-T')+'?epoch=stale&before=50')
        self.assertEqual(stale,(400,{'error':'History changed; reopen the conversation'}))
        self.assertEqual(stale,self.request('/sessions/%s?epoch=stale&before=0' % self.s.state['id']))
        # Any other epoch, or a revision this epoch never had, gets the full window.
        for other in ('?epoch=stale&revision=1','?epoch=%s&revision=99999' % full['epoch'],'?revision=3'):
            code,reset=self.request(self.path('task-T')+other)
            self.assertEqual((reset['start'],len(reset['messages']),reset['epoch']),(51,200,full['epoch']))
        self.assertEqual(self.request(self.path('nobody')),(404,{'error':'未找到该子 Agent'}))
        self.assertEqual(self.request(self.path('nobody')+'/stop',{})[0],404)
        # Transcript appends never moved the session revision; the progress did.
        self.assertEqual(self.s.state['revision'],revision+1)

    def test_stop_route_sends_stop_task_and_reports_failures(self):
        self.spawn('toolu_S'); self.child('toolu_S','s1','进行中')
        self.assertEqual(self.request(self.path('toolu_S')+'/stop',{})[0],400)
        self.started('task-S','toolu_S')
        revision=self.s.state['revision']
        self.assertEqual(self.request(self.path('toolu_S')+'/stop',{}),(200,{'ok':True}))
        self.assertEqual(self.s.sent[-1],{'type':'stop_task','taskId':'task-S','turnId':'turn-1'})
        entry=self.roster()['toolu_S']
        self.assertEqual((entry['stopRequested'],entry['stopError'],entry['canStop'],entry['status']),(True,None,True,'running'))
        self.assertGreater(self.s.state['revision'],revision)
        # A request already in flight is not sent again.
        self.assertEqual(self.request(self.path('task-S')+'/stop',{})[0],200)
        self.assertEqual(len([x for x in self.s.sent if x['type']=='stop_task']),1)
        # A refusal is shown and the stop can be retried.
        self.s.event({'type':'task_stop_result','taskId':'task-S','ok':False,'error':'Task not found'})
        entry=self.roster()['toolu_S']
        self.assertEqual((entry['stopRequested'],entry['stopError']),(False,'Task not found'))
        self.assertEqual(self.request(self.path('task-S')+'/stop',{})[0],200)
        self.assertEqual((len([x for x in self.s.sent if x['type']=='stop_task']),self.roster()['toolu_S']['stopError']),(2,None))
        self.task('task_notification','task-S',status='stopped',summary='已停止',output_file='')
        self.assertEqual(self.request(self.path('task-S')+'/stop',{})[0],400)
        # Nothing stops outside an active turn, and a dead worker records nothing.
        self.started('task-S2','toolu_S2'); self.s.state['busy']=False
        self.assertFalse(self.roster()['task-S2']['canStop'])
        self.assertEqual(self.request(self.path('task-S2')+'/stop',{})[0],400)
        self.s.state['busy']=True
        def fail(value): raise ValueError('远端进程已退出')
        self.s.send=fail
        self.assertEqual(self.request(self.path('task-S2')+'/stop',{}),(400,{'error':'远端进程已退出'}))
        self.assertFalse(self.roster()['task-S2']['stopRequested'])

    def test_long_parts_are_clipped_and_long_transcripts_trim_to_a_new_epoch(self):
        self.started('task-P','toolu_P')
        self.child('toolu_P','p1',[{'type':'text','text':'长'*20000},{'type':'thinking','thinking':'x'*40000},{'type':'text','text':'short'}])
        self.child('toolu_P','p2',[{'type':'tool_result','tool_use_id':'t','content':'y'*100000},
            {'type':'tool_result','tool_use_id':'u','content':[{'type':'image','source':{'data':'z'*50000}},{'type':'text','text':'caption'}]}],role='user')
        first=self.s.subagent_page('task-P'); messages=first['messages']
        for value in (messages[0]['content'][0]['text'],messages[0]['content'][1]['thinking'],messages[1]['content'][0]['output']):
            self.assertLessEqual(len(value.encode()),broker.SUBAGENT_PART_LIMIT); self.assertIn('已截断',value)
        self.assertTrue(messages[0]['content'][0]['text'].startswith('长'*1000))
        self.assertEqual(messages[0]['content'][2],{'type':'text','text':'short'})
        output=messages[1]['content'][1]['output']
        self.assertIn('已省略',output[0]['text']); self.assertEqual(output[1],{'type':'text','text':'caption'})
        # Over the message cap the front goes, down to 75%, under a new epoch.
        with patch.object(broker,'SUBAGENT_MESSAGE_LIMIT',20):
            for i in range(19): self.child('toolu_P','q%d' % i,'短消息')
        page=self.s.subagent_page('task-P')
        self.assertEqual((page['total'],page['truncated'],page['messages'][0]['id'],page['messages'][-1]['id']),(15,6,'q4','q18'))
        self.assertNotEqual(page['epoch'],first['epoch'])
        self.assertEqual(self.request(self.path('task-P')+'?epoch=%s&before=5' % first['epoch'])[0],400)
        code,reset=self.request(self.path('task-P')+'?epoch=%s&revision=%d' % (first['epoch'],first['revision']))
        self.assertEqual((reset['start'],reset['total']),(0,15))
        # Over the byte budget as well.
        with patch.object(broker,'SUBAGENT_BYTE_LIMIT',3000):
            self.child('toolu_P','r1','x'*1500)
        trimmed=self.s.subagent_page('task-P'); transcript=self.s.subagent_transcripts['task-P']
        self.assertGreater(trimmed['truncated'],6); self.assertEqual(trimmed['messages'][-1]['id'],'r1')
        self.assertLessEqual(transcript['bytes'],3000*3//4); self.assertNotEqual(trimmed['epoch'],page['epoch'])
        self.assertEqual(transcript['bytes'],sum(broker.json_size(m) for m in transcript['messages']))

    def test_tool_inputs_are_clipped_string_by_string(self):
        self.started('task-I','toolu_I')
        inputs={'command':'x'*40000,'nested':{'list':['y'*50000,'short',7],'flag':True},'note':'短','key'*10:'v'}
        self.child('toolu_I','i1',[{'type':'tool_use','id':'big-call','name':'Write','input':inputs}])
        value=self.s.subagent_page('task-I')['messages'][0]['content'][0]['input']
        for text in (value['command'],value['nested']['list'][0]):
            self.assertLessEqual(len(text.encode()),broker.SUBAGENT_PART_LIMIT); self.assertIn('…[已截断，原文',text)
        self.assertTrue(value['command'].startswith('x'*1000))
        self.assertEqual((value['nested']['list'][1:],value['nested']['flag'],value['note'],value['key'*10]),(['short',7],True,'短','v'))
        self.assertEqual(len(inputs['command']),40000)

    def test_one_oversized_message_becomes_a_notice_so_the_trim_holds(self):
        self.started('task-O','toolu_O')
        # Every part fits its cap, yet together they pass the trim target.
        self.child('toolu_O','huge',[{'type':'text','text':'z'*32000} for _ in range(100)])
        huge=self.s.subagent_page('task-O')['messages'][0]
        self.assertEqual((huge['id'],huge['role'],len(huge['content'])),('huge','assistant',1))
        self.assertIn('消息过大',huge['content'][0]['text'])
        # However large single messages get, every append leaves the transcript in budget.
        with patch.object(broker,'SUBAGENT_BYTE_LIMIT',200000):
            for i in range(12):
                parts=10 if i % 3 == 0 else 2
                self.child('toolu_O','m%d' % i,[{'type':'tool_use','id':'c%d-%d' % (i, n),'name':'Write','input':{'content':'w'*32000}} for n in range(parts)])
                transcript=self.s.subagent_transcripts['task-O']; last=transcript['messages'][-1]
                self.assertLessEqual(transcript['bytes'],200000)
                self.assertEqual(transcript['bytes'],sum(broker.json_size(m) for m in transcript['messages']))
                if parts == 10: self.assertIn('消息过大',last['content'][0]['text'])
                else: self.assertEqual([p['input']['content'] for p in last['content']],['w'*32000]*2)
        self.assertGreater(transcript['truncated'],0)

    def test_only_live_and_recently_read_finished_transcripts_stay_loaded(self):
        self.started('live','toolu_live'); self.child('toolu_live','l1','还在跑')
        live=self.s.subagent_transcripts['live']
        finished=lambda: [key for key in self.s.subagent_transcripts if key!='live']
        for i in range(10):
            self.started('t%d' % i,'u%d' % i); self.child('u%d' % i,'m','第 %d 个' % i)
            self.task('task_notification','t%d' % i,status='completed',summary='完成',output_file='')
        self.assertEqual(len(finished()),8)
        first=self.s.subagent_page('t0')
        for i in range(10): self.assertEqual(self.request(self.path('u%d' % i))[0],200)
        self.assertEqual(len(finished()),8); self.assertNotIn('t0',self.s.subagent_transcripts)
        # An evicted transcript reloads from its file unchanged and under its epoch,
        # so a client following it is not reset.
        code,again=self.request(self.path('t0'))
        self.assertEqual({k:again[k] for k in ('epoch','revision','total','messages')},{k:first[k] for k in ('epoch','revision','total','messages')})
        self.assertEqual(self.request(self.path('t0')+'?epoch=%s&revision=%d' % (first['epoch'],first['revision'])),(200,{'unchanged':True}))
        # A dirty transcript is written before it leaves memory.
        self.child('u9','late','迟到的消息')
        self.assertIn('t9',self.s.subagent_dirty)
        for i in range(8): self.request(self.path('u%d' % i))
        self.assertNotIn('t9',self.s.subagent_transcripts); self.assertNotIn('t9',self.s.subagent_dirty)
        self.assertEqual([m['id'] for m in json.loads(self.s.subagent_path('t9').read_text())['messages']],['m','late'])
        self.assertEqual([m['id'] for m in self.s.subagent_page('t9')['messages']],['m','late'])
        # The live transcript, though the oldest, was never evicted.
        self.assertIs(self.s.subagent_transcripts['live'],live)
        self.assertLessEqual(len(finished()),8)

    def test_transcripts_are_debounced_written_on_finish_and_restored_lazily(self):
        sid=self.s.state['id']; folder=broker.ROOT/'subagents'/sid
        self.started('task-R','toolu_R'); self.child('toolu_R','r1','第一条')
        self.timer.assert_called_once_with(broker.SUBAGENT_SAVE_DELAY,self.s.subagent_timer_fired)
        self.assertTrue(self.timer.return_value.daemon); self.timer.return_value.start.assert_called_once_with()
        self.assertFalse(folder.exists())
        self.s.subagent_timer_fired()
        saved=json.loads((folder/'task-R.json').read_text())
        self.assertEqual(set(saved),{'epoch','revision','truncated','messages','versions'})
        self.assertEqual(([m['id'] for m in saved['messages']],saved['revision'],saved['truncated']),
                         (['r1'],self.s.subagent_entries['task-R']['revision'],0))
        self.child('toolu_R','r2','第二条')
        self.task('task_notification','task-R',status='completed',summary='完成',output_file='')
        self.assertEqual([m['id'] for m in json.loads((folder/'task-R.json').read_text())['messages']],['r1','r2'])
        self.started('task-Q','toolu_Q'); self.child('toolu_Q','q1','还在跑')
        self.s.subagent_timer_fired()
        epoch=self.s.subagent_page('task-Q')['epoch']
        ghost=broker.ROOT/'subagents'/'ghost-session'; ghost.mkdir(parents=True); (ghost/'x.json').write_text('{}')
        (folder/'stray.json').write_text('{}')
        self.s.persist(); broker.SESSIONS.clear(); broker.load()
        restored=broker.SESSIONS[sid]
        self.assertEqual(restored.subagent_transcripts,{})
        self.assertFalse(ghost.exists()); self.assertFalse((folder/'stray.json').exists())
        roster=self.roster(restored)
        self.assertEqual((roster['task-R']['status'],roster['task-Q']['status']),('completed','unknown'))
        self.assertTrue(roster['task-Q']['endedAt'])
        page=restored.subagent_page('toolu_Q')
        self.assertEqual([m['id'] for m in page['messages']],['q1']); self.assertNotEqual(page['epoch'],epoch)
        self.assertEqual([m['id'] for m in restored.subagent_page('task-R')['messages']],['r1','r2'])
        # Deleting the session removes its transcripts.
        self.assertEqual(self.request('/sessions/%s/delete' % sid,{})[0],200)
        self.assertFalse(folder.exists())

    def test_roster_keeps_64_entries_and_prunes_the_oldest_finished_with_files(self):
        for i in range(64):
            self.started('t%02d' % i,'u%02d' % i); self.child('u%02d' % i,'m','x')
            if i: self.task('task_notification','t%02d' % i,status='completed',summary='完成',output_file='')
        self.s.subagent_timer_fired()
        self.s.event({'type':'interaction','id':'late','name':'Bash','input':{},'agentId':'t01'})
        self.started('t64','u64')
        roster=[x['id'] for x in self.s.state['subagentRoster']]
        self.assertEqual(len(roster),64)
        self.assertNotIn('t02',roster)
        for kept in ('t00','t01','t03','t64'): self.assertIn(kept,roster)
        self.assertFalse(self.s.subagent_path('t02').exists()); self.assertTrue(self.s.subagent_path('t03').exists())
        self.assertEqual(self.request(self.path('u02'))[0],404)

    def test_malformed_child_events_do_not_stop_the_main_stream(self):
        lines=[{'type':'assistant','uuid':'bad','parent_tool_use_id':'toolu_Z','message':{'role':'assistant','content':['not a block']}},
               {'type':'assistant','uuid':'main','parent_tool_use_id':None,'message':{'role':'assistant','content':[{'type':'text','text':'主线程'}]}}]
        self.s.process=type('Process',(),{'stdout':iter(json.dumps(x)+'\n' for x in lines),'poll':lambda self:0})()
        with patch.object(broker.traceback,'print_exc') as report: self.s.read()
        report.assert_called_once_with()
        self.assertEqual(self.s.state['messages'][-1]['content'][0]['text'],'主线程')

    def test_keys_outside_a_plain_id_never_leave_the_session_folder(self):
        for key in ('../../escape','a/b','.hidden','名字'):
            name=broker.subagent_filename(key)
            self.assertTrue(name.startswith('_') and name.endswith('.json') and '/' not in name)
        self.assertEqual(broker.subagent_filename('toolu_01ABC-x'),'toolu_01ABC-x.json')

class CodexSubagentTests(unittest.TestCase):
    # Ids and frame shapes follow the 2026-10-19 probe (codex-cli 0.162.1).
    MAIN='01a152fe-b9a9-76f1-90cd-1b149f05aaa5'; MAIN_TURN='01a152fe-c685-7c01-86c9-ec81efcf9f77'
    CHILD='01a152fe-ef63-7ef1-bf21-c6c8ce63afc2'; CHILD_TURN='01a152fe-ef6c-7280-80fa-6a7bd4d9a21e'
    CALL='call_8a85e75fca314da58122d77408df1939'
    LABEL={'id':CHILD,'agentId':CHILD,'title':'list_files','type':'/root/list_files'}
    def setUp(self):
        process_guard=patch.object(broker.subprocess,'Popen',side_effect=AssertionError('contract tests must not launch a real process'))
        process_guard.start(); self.addCleanup(process_guard.stop)
        timer=patch.object(broker.threading,'Timer'); self.timer=timer.start(); self.addCleanup(timer.stop)
        broker.TOKEN='test-token'; broker.SESSIONS.clear(); broker.CODEX_MODELS=None
        self.s,self.fake=self.codex('codex-'+self._testMethodName)
    def codex(self, identity, attached=True):
        s=broker.Session(dict(id=identity,provider='codex',cwd=folder.name,title='Codex',model='gpt-codex',thinking='medium',
            busy=False,archived=False,updated=0,revision=0,completed=0,messages=[],interactions=[],error=None,resume=self.MAIN))
        fake=FakeCodex(); fake.results['turn/start']={'turn':{'id':self.MAIN_TURN,'status':'inProgress'}}
        s.codex=fake; s.codex_attached=attached; broker.SESSIONS[identity]=s
        if attached: s.prompt({'text':'Spawn exactly one sub-agent','requestId':'request-1'})
        return s,fake
    def request(self,path,body=None):
        handler=object.__new__(broker.Handler); raw=json.dumps(body or {}).encode()
        handler.path=path; handler.headers={'Authorization':'Bearer test-token','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw); result=[]
        handler.respond=lambda code,payload:result.append((code,payload))
        handler.handle_request(body is not None)
        return result[0]
    def path(self,key,s=None): return '/sessions/'+(s or self.s).state['id']+'/subagents/'+key
    def frame(self,method,thread,s=None,**params):
        s=s or self.s; s.codex_frame(s.codex,{'method':method,'params':{'threadId':thread,**params}})
    def item(self,thread,item,completed=True,turn=None,at=1792393801581,s=None):
        key='completedAtMs' if completed else 'startedAtMs'
        self.frame('item/completed' if completed else 'item/started',thread,s,item=item,
                   turnId=turn or (self.MAIN_TURN if thread==self.MAIN else self.CHILD_TURN),**{key:at})
    def activity(self,kind,child=None,item_id=None,path='/root/list_files',model=None,parent=None,s=None):
        # The parent reports each activity twice, in item/started and item/completed.
        item={'type':'subAgentActivity','model':model,'reasoningEffort':'high' if model else None,
              'id':item_id or (self.CALL if kind=='started' else 'subagent-completed-'+self.CHILD_TURN),
              'kind':kind,'agentThreadId':child or self.CHILD,'agentPath':path}
        for completed in (False,True): self.item(parent or self.MAIN,item,completed,s=s)
    def spawn(self,s=None): self.activity('started',model='gpt-6-astra',s=s)
    def child_turn(self,turn=None,child=None,s=None):
        self.frame('turn/started',child or self.CHILD,s,turn={'id':turn or self.CHILD_TURN,'rootTurnId':self.MAIN_TURN,'items':[],
                   'itemsView':'notLoaded','status':'inProgress','error':None,'startedAt':1792393801,'completedAt':None,'durationMs':None})
    def child_done(self,status='completed',text='a.txt, b.txt, notes.txt',turn=None,child=None,duration=13430,error=None,s=None):
        items=[{'type':'agentMessage','id':'msg_child','text':text,'phase':'final_answer'}] if text else []
        self.frame('turn/completed',child or self.CHILD,s,turn={'id':turn or self.CHILD_TURN,'rootTurnId':self.MAIN_TURN,'items':items,
                   'itemsView':'summary','status':status,'error':error,'startedAt':1792393801,'completedAt':1792393815,'durationMs':duration})
    def child_work(self,child=None,s=None):
        child=child or self.CHILD
        command={'type':'commandExecution','id':'exec-4348f9d8','command':"/bin/bash -lc 'ls -A1'",'cwd':'/tmp/probe',
                 'status':'inProgress','aggregatedOutput':None,'exitCode':None}
        self.item(child,command,False,at=1792393811458,s=s)
        self.item(child,dict(command,status='completed',aggregatedOutput='a.txt\nb.txt\nnotes.txt\n',exitCode=0),at=1792393811458,s=s)
        self.frame('thread/tokenUsage/updated',child,s,turnId=self.CHILD_TURN,
                   tokenUsage={'total':{'totalTokens':21206},'last':{'totalTokens':21206},'modelContextWindow':258400})
        message={'type':'agentMessage','id':'msg_child','text':'','phase':'final_answer'}
        self.item(child,message,False,at=1792393814037,s=s)
        for delta in ('a','.txt, b.txt, notes.txt'):
            self.frame('item/agentMessage/delta',child,s,turnId=self.CHILD_TURN,itemId='msg_child',delta=delta)
        self.item(child,dict(message,text='a.txt, b.txt, notes.txt'),at=1792393814357,s=s)
        self.frame('thread/tokenUsage/updated',child,s,turnId=self.CHILD_TURN,
                   tokenUsage={'total':{'totalTokens':42456},'last':{'totalTokens':21250},'modelContextWindow':258400})
    def items(self,fake,pages):
        """thread/items/list answers by thread: pages in order, or an error raised every time."""
        plain=fake.request
        def request(method,params,timeout=60):
            if method!='thread/items/list': return plain(method,params,timeout)
            fake.calls.append((method,params)); answer=pages[params['threadId']]
            answer=answer.pop(0) if isinstance(answer,list) else answer
            if isinstance(answer,Exception): raise answer
            return answer
        fake.request=request
    def roster(self,s=None): return {x['id']:x for x in (s or self.s).snapshot()['subagents']}
    def main(self,identity,s=None): return next((m for m in (s or self.s).state['messages'] if m['id']==identity),None)

    def test_probe_sequence_builds_the_child_transcript_and_answers_its_card(self):
        # The child's first frames arrive before the parent reports it; they are not followed.
        self.frame('thread/status/changed',self.CHILD,status={'type':'idle'})
        self.frame('mcpServer/startupStatus/updated',self.CHILD,name='codex_apps',status='starting')
        self.assertEqual((self.s.state.get('subagentRoster'),self.s.codex_pending),(None,[]))
        revision=self.s.state['revision']
        self.spawn()
        entry=self.roster()[self.CHILD]
        self.assertEqual(list(entry),list(broker.SUBAGENT_KEYS))
        self.assertEqual((entry['kind'],entry['taskId'],entry['toolUseIds'],entry['turnId'],entry['description'],entry['subagentType'],
                          entry['status'],entry['background'],entry['usage'],entry['endedAt'],entry['canStop'],entry['messageCount']),
                         ('codex',self.CHILD,[self.CALL],None,'list_files','/root/list_files','running',None,None,None,False,0))
        self.assertEqual(entry['startedAt'],'2026-10-19T07:10:01.581Z')
        # The main turn that reported it places it in the snapshot once it has finished.
        self.assertEqual((self.s.subagent_entries[self.CHILD]['model'],self.s.subagent_entries[self.CHILD]['parentTurnId']),
                         ('gpt-6-astra',self.MAIN_TURN))
        self.assertGreater(self.s.state['revision'],revision)
        # The start reads as an agent/spawnAgent call in the parent's transcript, open until the child ends.
        self.assertEqual(self.main('codex-tool:'+self.CALL)['content'],[{'type':'tool_use','tool_call_id':self.CALL,
            'tool_name':'agent/spawnAgent','input':{'agentPath':'/root/list_files','model':'gpt-6-astra'}}])
        self.assertIsNone(self.main('codex-result:'+self.CALL))
        self.child_turn()
        self.assertEqual((self.roster()[self.CHILD]['turnId'],self.roster()[self.CHILD]['canStop']),(self.CHILD_TURN,True))
        before=json.loads(json.dumps(self.s.state['messages'])); versions=dict(self.s.message_versions)
        self.child_work()
        page=self.s.subagent_page(self.CALL)
        self.assertEqual([m['id'] for m in page['messages']],['codex-tool:exec-4348f9d8','codex-result:exec-4348f9d8','codex:msg_child'])
        self.assertEqual(page['messages'][0]['content'],[{'type':'tool_use','tool_call_id':'exec-4348f9d8','tool_name':'shell',
            'input':{'command':"/bin/bash -lc 'ls -A1'",'cwd':'/tmp/probe'}}])
        self.assertEqual(page['messages'][1]['content'][0]['output'],[{'type':'text','text':'a.txt\nb.txt\nnotes.txt\n'}])
        # Deltas are not followed: the reply appears complete, once.
        self.assertEqual(page['messages'][2]['content'],[{'type':'text','text':'a.txt, b.txt, notes.txt'}])
        self.assertEqual((page['entry']['usage'],page['entry']['lastToolName']),({'totalTokens':42456,'toolUses':1,'durationMs':0},'shell'))
        # None of the child's frames reached the main thread.
        self.assertEqual((self.s.state['messages'],self.s.message_versions),(before,versions))
        self.assertEqual((self.s.state['context'],self.s.state['busy'],self.s.state['turnId']),(None,True,self.MAIN_TURN))
        self.child_done()
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['summary'],entry['usage'],entry['endedAt'],entry['canStop']),
                         ('completed','a.txt, b.txt, notes.txt',{'totalTokens':42456,'toolUses':1,'durationMs':13430},'2026-10-19T07:10:15.000Z',False))
        self.assertTrue(self.s.state['busy'])
        self.assertEqual([m['id'] for m in json.loads(self.s.subagent_path(self.CHILD).read_text())['messages']],
                         ['codex-tool:exec-4348f9d8','codex-result:exec-4348f9d8','codex:msg_child'])
        self.assertEqual(self.main('codex-result:'+self.CALL)['content'],[{'type':'tool_result','tool_call_id':self.CALL,
            'output':[{'type':'text','text':'a.txt, b.txt, notes.txt'}],'is_error':False}])
        # The parent's own completion report changes nothing more.
        messages=json.loads(json.dumps(self.s.state['messages']))
        self.activity('completed')
        self.assertEqual((self.roster()[self.CHILD],self.s.state['messages']),(entry,messages))

    def test_child_frames_leave_the_main_thread_exactly_as_before(self):
        def main_sequence(s,child=lambda step:None):
            frame=lambda method,**params:self.frame(method,self.MAIN,s,**params)
            frame('turn/started',turn={'id':self.MAIN_TURN,'rootTurnId':self.MAIN_TURN,'items':[],'status':'inProgress'})
            user={'type':'userMessage','id':'01a152fe-dc8e','clientId':None,'content':[{'type':'text','text':'Spawn exactly one sub-agent'}]}
            self.item(self.MAIN,user,False,at=1792393796751,s=s); self.item(self.MAIN,user,at=1792393796751,s=s)
            note={'type':'agentMessage','id':'msg_note','text':'','phase':'commentary'}
            self.item(self.MAIN,note,False,at=1792393799795,s=s)
            child('start')
            for delta in ('I’ll have one sub-agent ','list the files.'):
                frame('item/agentMessage/delta',turnId=self.MAIN_TURN,itemId='msg_note',delta=delta)
            child('work')
            self.item(self.MAIN,dict(note,text='I’ll have one sub-agent list the files.'),at=1792393800521,s=s)
            wait={'type':'collabAgentToolCall','id':'call_wait','tool':'wait','status':'inProgress','senderThreadId':self.MAIN,
                  'receiverThreadIds':[],'prompt':None,'model':None,'reasoningEffort':None,'agentsStates':{}}
            self.item(self.MAIN,wait,False,at=1792393805937,s=s)
            frame('thread/tokenUsage/updated',turnId=self.MAIN_TURN,tokenUsage={'total':{'totalTokens':21401},'last':{'totalTokens':21401},'modelContextWindow':258400})
            child('done')
            self.item(self.MAIN,dict(wait,status='completed'),at=1792393815014,s=s)
            final={'type':'agentMessage','id':'msg_final','text':'','phase':'final_answer'}
            self.item(self.MAIN,final,False,at=1792393817561,s=s)
            frame('item/agentMessage/delta',turnId=self.MAIN_TURN,itemId='msg_final',delta='a.txt, b.txt')
            self.item(self.MAIN,dict(final,text='a.txt, b.txt, notes.txt'),at=1792393817562,s=s)
            frame('thread/tokenUsage/updated',turnId=self.MAIN_TURN,tokenUsage={'total':{'totalTokens':64366},'last':{'totalTokens':21522},'modelContextWindow':258400})
            frame('turn/completed',turn={'id':self.MAIN_TURN,'status':'completed','items':[dict(final,text='a.txt, b.txt, notes.txt')]})
        observed=[]
        def child(step):
            # thread/started registers the child without writing to the parent's transcript.
            if step=='start':
                self.s.codex_frame(self.fake,{'method':'thread/started','params':{'thread':{'id':self.CHILD,'parentThreadId':self.MAIN}}})
                self.child_turn()
            elif step=='work': self.child_work()
            else:
                self.child_done(); observed.append((self.s.state['busy'],self.s.state['turnState'],self.s.state['context']['tokens']))
        plain,_=self.codex('codex-plain-main')
        main_sequence(plain); main_sequence(self.s,child)
        view=lambda s:([(m['id'],m['role'],m['content']) for m in s.state['messages']],
                       {k:s.state.get(k) for k in ('busy','turnId','turnState','completed','error','cancelled','interactions')},
                       {k:v for k,v in s.state['context'].items() if k!='reportedAt'})
        self.assertEqual(view(self.s),view(plain))
        self.assertEqual(observed,[(True,'running',21401)])
        self.assertEqual(self.s.state['completed'],1)
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['messageCount'],entry['summary']),('completed',3,'a.txt, b.txt, notes.txt'))
        self.assertEqual(plain.snapshot()['subagents'],[])

    def test_collab_calls_register_receivers_with_mapped_states(self):
        spawn={'type':'collabAgentToolCall','id':'call_spawn','tool':'spawnAgent','status':'completed','senderThreadId':self.MAIN,
               'receiverThreadIds':['child-q'],'prompt':'检查测试\n只读','model':'gpt-6-mini','reasoningEffort':None,
               'agentsStates':{'child-q':{'status':'pendingInit','message':None}}}
        # The child exists once the call completes; the started item names no receiver yet.
        self.item(self.MAIN,dict(spawn,status='inProgress',receiverThreadIds=[],agentsStates={}),False); self.item(self.MAIN,spawn)
        entry=self.roster()['child-q']
        self.assertEqual((entry['kind'],entry['status'],entry['toolUseIds'],entry['description'],entry['subagentType'],entry['canStop']),
                         ('codex','queued',['call_spawn'],'检查测试',None,False))
        self.assertEqual(self.s.subagent_entries['child-q']['model'],'gpt-6-mini')
        # The collab card itself keeps its earlier shape.
        self.assertEqual(self.main('codex-tool:call_spawn')['content'][0],{'type':'tool_use','tool_call_id':'call_spawn',
            'tool_name':'agent/spawnAgent','input':{'prompt':'检查测试\n只读','receivers':['child-q']}})
        states={'child-q':{'status':'completed','message':'全部通过'},'child-e':{'status':'errored','message':'模型超时'},
                'child-i':{'status':'interrupted'},'child-s':{'status':'shutdown'},'child-n':{'status':'notFound'},
                'child-r':{'status':'running'},self.MAIN:{'status':'running'}}
        wait={'type':'collabAgentToolCall','id':'call_wait','tool':'wait','status':'completed','senderThreadId':self.MAIN,
              'receiverThreadIds':['child-q','child-e'],'prompt':None,'model':None,'reasoningEffort':None,'agentsStates':states}
        self.item(self.MAIN,wait)
        roster=self.roster()
        self.assertEqual({key:value['status'] for key,value in roster.items()},{'child-q':'completed','child-e':'failed','child-i':'stopped',
                         'child-s':'completed','child-n':'unknown','child-r':'running'})
        self.assertEqual((roster['child-q']['summary'],roster['child-e']['error'],roster['child-q']['toolUseIds']),('全部通过','模型超时',['call_spawn']))
        self.assertTrue(roster['child-q']['endedAt'] and roster['child-n']['endedAt'])
        self.assertNotIn(self.MAIN,self.s.subagent_entries)
        # A finished child never revives from a later state report.
        self.item(self.MAIN,dict(wait,id='call_wait_2',agentsStates={'child-q':{'status':'running'}}))
        self.assertEqual(self.roster()['child-q']['status'],'completed')

    def test_thread_started_registers_children_of_this_thread_and_of_its_children(self):
        started=lambda thread:self.s.codex_frame(self.fake,{'method':'thread/started','params':{'thread':thread}})
        started({'id':self.MAIN,'parentThreadId':None,'agentNickname':None,'agentRole':None})
        self.assertIsNone(self.s.state.get('subagentRoster'))
        started({'id':'child-a','parentThreadId':self.MAIN,'agentNickname':'Hubble','agentRole':'explorer','model':'gpt-6-mini'})
        entry=self.roster()['child-a']
        self.assertEqual((entry['status'],entry['description'],entry['subagentType'],entry['toolUseIds'],entry['turnId']),
                         ('running','Hubble','explorer',[],None))
        started({'id':'child-b','parentThreadId':'child-a','agentNickname':'Kepler','agentRole':None})
        started({'id':'stranger','parentThreadId':'another-thread'})
        self.assertEqual(sorted(self.roster()),['child-a','child-b'])
        self.assertEqual(self.s.subagent_entries['child-b']['parentTurnId'],self.MAIN_TURN)
        # A child that spawns its own: the card and its answer go to that child's transcript.
        self.activity('started',child='child-g',item_id='call_g',path='/root/hubble/probe',parent='child-a')
        self.assertEqual(self.s.subagent_page('call_g')['entry']['id'],'child-g')
        self.child_turn(turn='turn-g',child='child-g')
        self.item('child-g',{'type':'agentMessage','id':'g1','text':'深层结果'},turn='turn-g')
        self.child_done(text='深层结果',turn='turn-g',child='child-g')
        parent=self.s.subagent_page('child-a')['messages']
        self.assertEqual([m['id'] for m in parent],['codex-tool:call_g','codex-result:call_g'])
        self.assertEqual(parent[1]['content'][0]['output'],[{'type':'text','text':'深层结果'}])
        self.assertEqual([m['id'] for m in self.s.subagent_page('child-g')['messages']],['codex:g1'])
        self.assertIsNone(self.main('codex-tool:call_g'))

    def test_history_registers_children_and_items_list_backfills_their_transcripts(self):
        # A session restored from disk: its last turn is known, its app-server is new.
        s,fake=self.codex('codex-history',attached=False); s.state['turnId']=self.MAIN_TURN
        fake.results['thread/resume']={'thread':{'id':self.MAIN,'model':'gpt-codex'}}
        record=lambda item,at:{'turnId':self.MAIN_TURN,'item':item,'startedAtMs':at,'completedAtMs':at}
        activity=lambda kind,child,item_id,path:{'type':'subAgentActivity','id':item_id,'kind':kind,'agentThreadId':child,'agentPath':path,'model':None}
        self.items(fake,{self.MAIN:[
            {'data':[record({'type':'userMessage','id':'u1','content':[{'type':'text','text':'派子 Agent'}]},1792393796751),
                     record(activity('started','child-a','call_a','/root/list_files'),1792393801581),
                     record(activity('started','child-b','call_b','/root/grep_todo'),1792393802000)],'nextCursor':'main-2'},
            {'data':[record(activity('completed','child-a','subagent-completed-a','/root/list_files'),1792393815013),
                     record(activity('started','child-c','call_c','/root/again'),1792393816000),
                     record(activity('completed','child-c','subagent-completed-c','/root/again'),1792393817000),
                     record(activity('interacted','child-c','interacted-c','/root/again'),1792393818000),
                     record({'type':'agentMessage','id':'a1','text':'完成'},1792393819000)],'nextCursor':None}],
            'child-a':[{'data':[{'turnId':'turn-a','item':{'type':'commandExecution','id':'exec-a','command':'ls','cwd':'/tmp',
                                 'status':'completed','aggregatedOutput':'a.txt\n'},'startedAtMs':1792393811458,'completedAtMs':1792393811458}],
                        'nextCursor':'a-2'},
                       {'data':[{'turnId':'turn-a','item':{'type':'agentMessage','id':'msg-a','text':'a.txt'},
                                 'startedAtMs':1792393814037,'completedAtMs':1792393814357}],'nextCursor':None}],
            'child-b':ValueError('Codex 拒绝 thread/items/list：thread not found')})
        s.codex_ensure(True)
        roster=self.roster(s)
        self.assertEqual({key:value['status'] for key,value in roster.items()},{'child-a':'completed','child-b':'unknown','child-c':'unknown'})
        self.assertEqual((roster['child-a']['startedAt'],roster['child-a']['endedAt'],roster['child-a']['toolUseIds'],roster['child-a']['description']),
                         ('2026-10-19T07:10:01.581Z','2026-10-19T07:10:15.013Z',['call_a'],'list_files'))
        self.assertEqual((roster['child-b']['canStop'],roster['child-c']['endedAt']),(False,None))
        # History rebuilds the parent's cards: a finished child's is answered, the others stay open.
        self.assertEqual(self.main('codex-result:call_a',s)['content'][0]['output'],[{'type':'text','text':'子 Agent 已完成'}])
        self.assertIsNone(self.main('codex-result:call_b',s))
        self.assertEqual([m['id'] for m in s.state['messages'] if m['id'].startswith('codex-tool:')],['codex-tool:call_a','codex-tool:call_b','codex-tool:call_c'])
        # Opening a child whose transcript is empty reads its thread, oldest first, once.
        code,page=self.request(self.path('call_a',s))
        self.assertEqual((code,page['entry']['id'],[m['id'] for m in page['messages']]),
                         (200,'child-a',['codex-tool:exec-a','codex-result:exec-a','codex:msg-a']))
        reads=[params for method,params in fake.calls if method=='thread/items/list' and params['threadId']=='child-a']
        self.assertEqual(reads,[{'threadId':'child-a','sortDirection':'asc','limit':100},
                                {'threadId':'child-a','sortDirection':'asc','limit':100,'cursor':'a-2'}])
        self.assertEqual(self.request(self.path('child-a',s))[1]['total'],3)
        self.assertEqual(len([1 for method,params in fake.calls if method=='thread/items/list' and params['threadId']=='child-a']),2)
        self.assertTrue(s.subagent_path('child-a').exists())
        # A failed read leaves the transcript empty and is retried later, not on every follow read.
        self.assertEqual(self.request(self.path('call_b',s))[1]['total'],0)
        self.assertEqual(self.request(self.path('call_b',s))[1]['total'],0)
        failed=lambda:len([1 for method,params in fake.calls if method=='thread/items/list' and params['threadId']=='child-b'])
        self.assertEqual(failed(),1)
        s.codex_backfills['child-b']=time.monotonic()-1
        self.request(self.path('call_b',s))
        self.assertEqual(failed(),2)

    def test_backfill_without_a_live_app_server_reads_outside_the_session_lock(self):
        self.activity('started',child='child-x',item_id='call_x',path='/root/x')
        self.s.codex_exit(self.fake,'Codex app-server 已退出')
        self.assertEqual(self.roster()['child-x']['status'],'unknown')
        reader=FakeCodex(); observed=[]
        def probe():
            acquired=broker.LOCK.acquire(blocking=False); observed.append(acquired)
            if acquired: broker.LOCK.release()
        def page(method,params,timeout=60):
            reader.calls.append((method,params)); worker=threading.Thread(target=probe); worker.start(); worker.join()
            return {'data':[{'turnId':'turn-x','item':{'type':'agentMessage','id':'x1','text':'只读结果'}}],'nextCursor':None}
        reader.request=page
        with patch.object(broker,'CodexAppServer',return_value=reader) as factory:
            code,window=self.request(self.path('call_x'))
        factory.assert_called_once_with(folder.name,home=self.s.state['codexHome'])
        self.assertEqual((code,[m['id'] for m in window['messages']]),(200,['codex:x1']))
        self.assertEqual(([c[0] for c in reader.calls],observed,reader.closed),(['initialize','thread/items/list'],[True],True))

    def test_frames_of_an_unregistered_thread_wait_for_it_and_then_replay(self):
        self.child_turn(); self.child_work()
        # Only followed methods wait: turn/started, two items twice, two usage reports.
        self.assertEqual((self.s.state.get('subagentRoster'),len(self.s.codex_pending)),(None,7))
        self.spawn()
        page=self.s.subagent_page(self.CHILD)
        self.assertEqual([m['id'] for m in page['messages']],['codex-tool:exec-4348f9d8','codex-result:exec-4348f9d8','codex:msg_child'])
        self.assertEqual((page['entry']['turnId'],page['entry']['usage'],page['entry']['canStop']),
                         (self.CHILD_TURN,{'totalTokens':42456,'toolUses':1,'durationMs':0},True))
        self.assertEqual(self.s.codex_pending,[])
        # At most 256 frames wait, each at most 30 s.
        clock=[1000.0]
        with patch.object(broker.time,'monotonic',side_effect=lambda:clock[0]):
            for i in range(300): self.item('late',{'type':'agentMessage','id':'m%d' % i,'text':'x'},turn='t')
            self.assertEqual([x[2]['params']['item']['id'] for x in self.s.codex_pending],['m%d' % i for i in range(44,300)])
            clock[0]+=31
            self.item('other',{'type':'agentMessage','id':'o1','text':'y'},turn='t')
            self.assertEqual([x[1] for x in self.s.codex_pending],['other'])
            self.activity('started',child='late',item_id='call_late',path='/root/late')
        self.assertEqual(self.s.subagent_page('late')['total'],0)

    def test_child_requests_are_labelled_and_cleared_with_their_own_turn(self):
        self.spawn(); self.child_turn()
        self.s.codex_frame(self.fake,{'method':'thread/started','params':{'thread':{'id':'child-2','parentThreadId':self.MAIN,'agentNickname':'Kepler'}}})
        ask=lambda wire,method,thread,**params:self.s.codex_frame(self.fake,{'id':wire,'method':method,'params':{'threadId':thread,**params}})
        ask(1,'item/commandExecution/requestApproval',self.MAIN,turnId=self.MAIN_TURN,itemId='m1',command=['git','status'],cwd=folder.name)
        ask(2,'item/commandExecution/requestApproval',self.CHILD,turnId=self.CHILD_TURN,itemId='c1',command='rm -rf build',cwd=folder.name,reason='clean')
        ask(3,'item/tool/requestUserInput','child-2',turnId='turn-2',itemId='q1',isBlocking=True,
            questions=[{'id':'pick','question':'Which?','header':'A','options':[{'label':'one'}]}])
        ask(4,'item/fileChange/requestApproval',self.CHILD,turnId=self.CHILD_TURN,itemId='f1',reason='edit')
        ask(5,'item/commandExecution/requestApproval','stranger',turnId='t',itemId='s1',command=['ls'])
        self.assertEqual(self.fake.responses,[(5,None,{'code':-32602,'message':'thread id does not match this session'})])
        interactions={x['id']:x for x in self.s.snapshot()['interactions']}
        self.assertEqual(list(interactions),['codex-request-1','codex-request-2','codex-request-3','codex-request-4'])
        self.assertNotIn('subagent',interactions['codex-request-1'])
        self.assertEqual(interactions['codex-request-2'],{'id':'codex-request-2','type':'interaction','name':'shell','title':'Codex 请求确认',
            'input':{'command':'rm -rf build','cwd':folder.name,'reason':'clean'},'subagent':self.LABEL})
        self.assertEqual((interactions['codex-request-3']['name'],interactions['codex-request-3']['subagent']),
                         ('AskUserQuestion',{'id':'child-2','agentId':'child-2','title':'Kepler','type':None}))
        self.assertEqual(interactions['codex-request-4']['subagent'],self.LABEL)
        # The existing answer route reaches the child's request.
        self.assertEqual(self.request('/sessions/%s/answer' % self.s.state['id'],{'id':'codex-request-2','allow':True}),(200,{'ok':True}))
        self.assertEqual(self.fake.responses[-1],(2,{'decision':'accept'},None))
        # The main turn's end clears only the main thread's requests.
        self.frame('turn/completed',self.MAIN,turn={'id':self.MAIN_TURN,'status':'completed'})
        self.assertEqual([x['id'] for x in self.s.state['interactions']],['codex-request-3','codex-request-4'])
        self.assertEqual(sorted(self.s.codex_interactions),['codex-request-3','codex-request-4'])
        # Both children stay listed while they run and wait on the user.
        self.assertEqual(sorted(x['id'] for x in self.s.snapshot()['subagents']),[self.CHILD,'child-2'])
        # A child's turn end clears that child's requests; a resolution from the runtime clears one.
        self.child_done()
        self.assertEqual([x['id'] for x in self.s.state['interactions']],['codex-request-3'])
        self.frame('serverRequest/resolved','child-2',requestId=3)
        self.assertEqual((self.s.state['interactions'],self.s.codex_interactions),([],{}))
        self.assertEqual(len(self.fake.responses),2)

    def test_stop_interrupts_the_child_turn_and_its_end_reports_stopped(self):
        self.spawn()
        self.assertEqual(self.request(self.path(self.CALL)+'/stop',{}),(400,{'error':'该子 Agent 当前无法单独停止'}))
        self.child_turn()
        # A child outlives the main turn and can still be stopped on its own.
        self.frame('turn/completed',self.MAIN,turn={'id':self.MAIN_TURN,'status':'completed'})
        self.assertTrue(self.roster()[self.CHILD]['canStop'])
        revision=self.s.state['revision']
        self.assertEqual(self.request(self.path(self.CALL)+'/stop',{}),(200,{'ok':True}))
        self.assertEqual(self.fake.calls[-1],('turn/interrupt',{'threadId':self.CHILD,'turnId':self.CHILD_TURN}))
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['stopRequested'],entry['stopError'],entry['status'],entry['canStop']),(True,None,'running',True))
        self.assertGreater(self.s.state['revision'],revision)
        self.assertEqual(self.request(self.path(self.CHILD)+'/stop',{}),(200,{'ok':True}))
        self.assertEqual([c for c in self.fake.calls if c[0]=='turn/interrupt'],[('turn/interrupt',{'threadId':self.CHILD,'turnId':self.CHILD_TURN})])
        self.child_done('interrupted',text=None,duration=2000)
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['canStop'],entry['usage']['durationMs']),('stopped',False,2000))
        self.assertEqual(self.main('codex-result:'+self.CALL)['content'][0],{'type':'tool_result','tool_call_id':self.CALL,
            'output':[{'type':'text','text':'子 Agent 已停止'}],'is_error':True})
        self.assertEqual(self.request(self.path(self.CALL)+'/stop',{})[0],400)
        # A refused interrupt reports the runtime's reason and records nothing.
        self.activity('started',child='child-r',item_id='call_r',path='/root/r'); self.child_turn(turn='turn-r',child='child-r')
        plain=self.fake.request
        def refuse(method,params,timeout=60):
            if method=='turn/interrupt': raise ValueError('Codex 拒绝 turn/interrupt：no active turn')
            return plain(method,params,timeout)
        self.fake.request=refuse
        self.assertEqual(self.request(self.path('call_r')+'/stop',{}),(400,{'error':'Codex 拒绝 turn/interrupt：no active turn'}))
        self.assertFalse(self.roster()['child-r']['stopRequested'])
        self.fake.closed=True
        self.assertEqual(self.request(self.path('call_r')+'/stop',{}),(400,{'error':'Codex app-server 已退出，无法停止子 Agent'}))

    def test_snapshot_summary_and_transcript_routes_for_a_codex_entry(self):
        self.spawn(); self.child_turn(); self.child_work()
        full=self.s.snapshot(); page=self.s.snapshot(turns='50')
        self.assertEqual(page['subagents'],full['subagents'])
        entry=full['subagents'][0]
        self.assertEqual(list(entry),list(broker.SUBAGENT_KEYS))
        self.assertEqual((entry['id'],entry['kind'],entry['taskId'],entry['toolUseIds'],entry['turnId'],entry['status'],entry['canStop'],
                          entry['messageCount'],entry['stopRequested'],entry['stopError'],entry['error']),
                         (self.CHILD,'codex',self.CHILD,[self.CALL],self.CHILD_TURN,'running',True,3,False,None,None))
        for value in (full,page): self.assertNotIn('subagentRoster',value)
        listed=next(x for x in self.request('/sessions')[1]['sessions'] if x['id']==self.s.state['id'])
        self.assertEqual((listed['runningSubagents'],self.s.summary()['runningSubagents']),(1,1))
        for key in (self.CHILD,self.CALL):
            code,window=self.request(self.path(key))
            self.assertEqual(set(window),{'entry','epoch','revision','total','truncated','start','messages'})
            self.assertEqual((code,window['entry'],window['total'],window['start'],window['truncated']),(200,entry,3,0,0))
        query='?epoch=%s&revision=%d' % (window['epoch'],window['revision'])
        self.assertEqual(self.request(self.path(self.CALL)+query),(200,{'unchanged':True}))
        # A plain append moves only the transcript's revision.
        revision=self.s.state['revision']
        self.item(self.CHILD,{'type':'reasoning','id':'r1','summary':['检查目录'],'content':[]})
        self.assertEqual(self.s.state['revision'],revision)
        code,delta=self.request(self.path(self.CALL)+query)
        self.assertEqual(([c['index'] for c in delta['changes']],delta['total']),([3],4))
        self.assertEqual(delta['changes'][0]['message']['content'][0]['source'],{'kind':'activity_summary','provider':'codex','itemId':'r1',
            'summaryParts':['检查目录'],'state':'final','turnId':self.CHILD_TURN})
        # The entry's end reaches a follower as a delta without messages.
        self.child_done()
        code,change=self.request(self.path(self.CALL)+'?epoch=%s&revision=%d' % (delta['epoch'],delta['revision']))
        self.assertEqual((change['changes'],change['entry']['status'],change['entry']['canStop']),([],'completed',False))
        self.assertEqual(self.request(self.path('nobody')),(404,{'error':'未找到该子 Agent'}))
        # Finished children of an earlier main turn drop out of the snapshot; their routes stay.
        self.s.state['turnId']='turn-next'
        self.assertEqual(self.s.snapshot()['subagents'],[])
        self.assertEqual(self.request(self.path(self.CALL))[0],200)

    def test_a_later_turn_revives_the_child_and_a_parent_report_can_end_it_first(self):
        self.spawn(); self.child_turn()
        self.child_done('failed',text=None,error={'message':'模型超时'},duration=1000)
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['error'],entry['usage']['durationMs']),('failed','模型超时',1000))
        self.assertEqual(self.main('codex-result:'+self.CALL)['content'][0]['output'],[{'type':'text','text':'模型超时'}])
        # A repeated end is applied once.
        self.child_done('failed',text=None,error={'message':'模型超时'},duration=1000)
        self.assertEqual(self.roster()[self.CHILD]['usage']['durationMs'],1000)
        # The parent sends more input; the child's next turn runs it again, from a clean state.
        self.activity('interacted',item_id='interacted-1')
        self.assertEqual(self.roster()[self.CHILD]['status'],'failed')
        self.child_turn(turn='turn-2')
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['turnId'],entry['error'],entry['endedAt'],entry['canStop']),('running','turn-2',None,None,True))
        # The parent's report may end it before the child's own turn end, which still adds its summary and time.
        self.activity('completed',item_id='subagent-completed-turn-2')
        self.assertEqual((self.roster()[self.CHILD]['status'],self.main('codex-result:'+self.CALL)['content'][0]['output']),
                         ('completed',[{'type':'text','text':'子 Agent 已完成'}]))
        self.child_done(text='修好了',turn='turn-2',duration=500)
        entry=self.roster()[self.CHILD]
        self.assertEqual((entry['status'],entry['summary'],entry['usage']['durationMs']),('completed','修好了',1500))
        self.assertEqual(self.main('codex-result:'+self.CALL)['content'][0],{'type':'tool_result','tool_call_id':self.CALL,
            'output':[{'type':'text','text':'修好了'}],'is_error':False})
        # A late copy of that turn's start does not revive it.
        self.child_turn(turn='turn-2')
        self.assertEqual(self.roster()[self.CHILD]['status'],'completed')

    def test_app_server_exit_and_service_restart_leave_running_children_unknown(self):
        self.spawn(); self.child_turn(); self.child_work()
        self.s.codex_frame(self.fake,{'id':9,'method':'item/fileChange/requestApproval','params':{'threadId':self.CHILD,'itemId':'f1'}})
        self.s.codex_exit(self.fake,'Codex app-server 已退出')
        entry=self.s.subagent_page(self.CHILD)['entry']
        self.assertEqual((entry['status'],entry['canStop'],bool(entry['endedAt']),self.s.state['interactions']),('unknown',False,True,[]))
        self.assertEqual(len(json.loads(self.s.subagent_path(self.CHILD).read_text())['messages']),3)
        # A service restart: the running child becomes unknown and its transcript loads from disk.
        restarted,_=self.codex('codex-restart')
        self.spawn(s=restarted); self.child_turn(s=restarted); self.child_work(s=restarted)
        restarted.subagent_timer_fired(); restarted.persist()
        broker.SESSIONS.clear(); broker.load()
        restored=broker.SESSIONS['codex-restart']
        self.assertEqual(restored.subagent_transcripts,{})
        entry=self.roster(restored)[self.CHILD]
        self.assertEqual((entry['status'],entry['toolUseIds'],entry['description']),('unknown',[self.CALL],'list_files'))
        code,window=self.request(self.path(self.CALL,restored))
        self.assertEqual((code,window['total']),(200,3))
        self.assertEqual(restored.codex_backfills,{self.CHILD:True})

class UpgradeLifecycleTests(unittest.TestCase):
    def test_changed_local_binary_does_not_interrupt_active_task(self):
        endpoint={'port':43210,'token':'fixture-token','pid':1234}
        with patch.dict(os.environ, {'PERCH_LOCAL_CODEX':'/new/codex'}), \
             patch.object(broker, 'running_endpoint', return_value=(endpoint, {'version':broker.SERVICE_VERSION,'implementation':broker.SOURCE_FINGERPRINT,'localCodexBinary':'/old/codex'})), \
             patch.object(broker, 'endpoint_request', return_value={'sessions':[{'id':'s','busy':True}]}), \
             patch.object(broker.os, 'kill') as kill:
            self.assertEqual(broker.reusable_endpoint(pathlib.Path('/fixture')),endpoint|{'restartPending':1})
            kill.assert_not_called()

    def test_unchanged_local_binary_reuses_bridge(self):
        endpoint={'port':43210,'token':'fixture-token','pid':1234}
        binary=str(pathlib.Path('/same/codex').resolve())
        with patch.dict(os.environ, {'PERCH_LOCAL_CODEX':binary}), \
             patch.object(broker, 'running_endpoint', return_value=(endpoint, {'version':broker.SERVICE_VERSION,'implementation':broker.SOURCE_FINGERPRINT,'localCodexBinary':binary})), \
             patch.object(broker, 'endpoint_request') as request:
            self.assertEqual(broker.reusable_endpoint(pathlib.Path('/fixture')),endpoint)
            request.assert_not_called()

    legacy_server = r'''
import json, os, pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root=pathlib.Path(os.environ['AWB_NATIVE_ROOT'])
token='legacy-token'
busy=os.environ.get('LEGACY_BUSY')=='1'
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if self.headers.get('Authorization')!='Bearer '+token:
            body={'error':'Unauthorized'}; status=401
        elif self.path=='/health': body={'version':1}; status=200
        elif self.path=='/sessions': body={'sessions':[{'id':'legacy-session','busy':busy,'pending':0}]}; status=200
        elif self.path=='/sessions/legacy-session': body={'id':'legacy-session','busy':busy,'pending':0}; status=200
        else: body={'error':'unknown'}; status=404
        data=json.dumps(body).encode(); self.send_response(status); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'endpoint.json').write_text(json.dumps({'port':server.server_port,'token':token,'pid':os.getpid()}))
server.serve_forever()
'''
    def endpoint(self, directory, pid=1234):
        value={'port':43210,'token':'fixture-token','pid':pid}
        path=pathlib.Path(directory)/'endpoint.json'; path.write_text(json.dumps(value))
        return path,value
    def health(self, **overrides):
        return {'version':broker.SERVICE_VERSION,'implementation':broker.SOURCE_FINGERPRINT}|overrides
    def test_current_service_is_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            with patch.object(broker,'endpoint_request',return_value=self.health()), patch.object(broker.os,'kill') as kill:
                self.assertEqual(broker.reusable_endpoint(path),endpoint)
                kill.assert_not_called()
    def test_fingerprint_reads_the_running_source_and_reports_nothing_when_absent(self):
        script=pathlib.Path(broker.__file__)
        self.assertEqual(broker.source_fingerprint(script),broker.SOURCE_FINGERPRINT)
        self.assertNotEqual(broker.SOURCE_FINGERPRINT,'')
        with tempfile.TemporaryDirectory() as directory:
            edited=pathlib.Path(directory)/'edited.py'
            edited.write_bytes(script.read_bytes()+b'\n# deployed change\n')
            self.assertNotEqual(broker.source_fingerprint(edited),broker.SOURCE_FINGERPRINT)
            self.assertEqual(broker.source_fingerprint(pathlib.Path(directory)/'missing.py'),'')
    def test_same_protocol_with_other_source_is_retired_when_idle(self):
        # A deployed change that keeps SERVICE_VERSION must still take effect.
        with tempfile.TemporaryDirectory() as directory:
            path,_=self.endpoint(directory)
            idle={'id':'s','busy':False,'pending':0,'turnState':'completed'}
            responses=[self.health(implementation='0123456789abcdef'),{'sessions':[idle]},idle,ConnectionRefusedError()]
            with patch.object(broker,'endpoint_request',side_effect=responses), patch.object(broker.os,'kill') as kill, patch.object(broker.time,'sleep'):
                self.assertIsNone(broker.reusable_endpoint(path))
                kill.assert_called_once_with(1234,broker.signal.SIGTERM)
    def test_same_protocol_with_other_source_waits_for_active_work(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            responses=[self.health(implementation='0123456789abcdef'),{'sessions':[{'id':'s','busy':True,'pending':0}]}]
            with patch.object(broker,'endpoint_request',side_effect=responses), patch.object(broker.os,'kill') as kill:
                self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':1})
                kill.assert_not_called()
    def test_service_predating_source_reporting_is_replaced_not_assumed_current(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            responses=[{'version':broker.SERVICE_VERSION},{'sessions':[{'id':'s','busy':True,'pending':0}]}]
            with patch.object(broker,'endpoint_request',side_effect=responses):
                self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':1})
    def test_unreadable_local_source_leaves_a_healthy_service_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            with patch.object(broker,'SOURCE_FINGERPRINT',''), \
                 patch.object(broker,'endpoint_request',return_value={'version':broker.SERVICE_VERSION}), \
                 patch.object(broker.os,'kill') as kill:
                self.assertEqual(broker.reusable_endpoint(path),endpoint)
                kill.assert_not_called()
    def test_active_legacy_service_is_preserved(self):
        sessions=({'id':'s','busy':True,'pending':0},{'id':'s','busy':False,'pending':1})
        sessions+=tuple({'id':'s','busy':False,'pending':0,'turnState':state}
            for state in ('submitting','submitted','accepted','running'))
        # A running subagent keeps the old service, from the list or the snapshot.
        sessions+=({'id':'s','busy':False,'pending':0,'runningSubagents':1},)
        for session in sessions:
            with self.subTest(session=session), tempfile.TemporaryDirectory() as directory:
                path,endpoint=self.endpoint(directory)
                responses=[{'version':broker.SERVICE_VERSION-1},{'sessions':[session]}]
                with patch.object(broker,'endpoint_request',side_effect=responses), patch.object(broker.os,'kill') as kill:
                    self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':1})
                    kill.assert_not_called()
    def test_running_subagent_in_snapshot_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            summary={'id':'s','busy':False,'pending':0,'turnState':'completed','runningSubagents':0}
            for status in ('queued','running'):
                snapshot=summary|{'subagents':[{'id':'old','status':'completed'},{'id':'child','status':status}]}
                with self.subTest(status=status), patch.object(broker,'endpoint_request',side_effect=[{'version':1},{'sessions':[summary]},snapshot]), \
                     patch.object(broker.os,'kill') as kill:
                    self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':1})
                    kill.assert_not_called()
        self.assertFalse(broker.active_session({'busy':False,'pending':0,'runningSubagents':0,
            'subagents':[{'status':s} for s in ('completed','failed','stopped','unknown')]}))
    def test_running_legacy_command_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            summary={'id':'s','busy':False,'pending':0,'turnState':'completed'}
            snapshot=summary|{'commandResult':{'status':'running'}}
            responses=[{'version':1},{'sessions':[summary]},snapshot]
            with patch.object(broker,'endpoint_request',side_effect=responses), patch.object(broker.os,'kill') as kill:
                self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':1})
                kill.assert_not_called()
    def test_unverifiable_legacy_service_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path,endpoint=self.endpoint(directory)
            with patch.object(broker,'endpoint_request',side_effect=[{'version':1},OSError('unavailable')]), patch.object(broker.os,'kill') as kill:
                self.assertEqual(broker.reusable_endpoint(path),endpoint|{'restartPending':-1})
                kill.assert_not_called()
    def test_idle_legacy_service_is_retired(self):
        with tempfile.TemporaryDirectory() as directory:
            path,_=self.endpoint(directory)
            idle={'id':'s','busy':False,'pending':0,'turnState':'completed'}
            responses=[{'version':1},{'sessions':[idle]},idle,ConnectionRefusedError()]
            with patch.object(broker,'endpoint_request',side_effect=responses), patch.object(broker.os,'kill') as kill, patch.object(broker.time,'sleep'):
                self.assertIsNone(broker.reusable_endpoint(path))
                kill.assert_called_once_with(1234,broker.signal.SIGTERM)
    def start_legacy(self, directory, busy=False):
        env=dict(os.environ,AWB_NATIVE_ROOT=directory,LEGACY_BUSY='1' if busy else '0')
        process=subprocess.Popen([sys.executable,'-c',self.legacy_server],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
        path=pathlib.Path(directory)/'endpoint.json'
        for _ in range(100):
            if process.poll() is not None:
                error=process.stderr.read(); process.stderr.close(); self.fail(error)
            try:
                endpoint=json.loads(path.read_text())
                if broker.endpoint_request(endpoint,'/health')['version']==1: return process,path
            except Exception: time.sleep(.02)
        process.terminate(); process.wait(timeout=2); process.stderr.close()
        self.fail('legacy fixture did not start')
    def stop_endpoint(self, endpoint):
        try: os.kill(endpoint['pid'],broker.signal.SIGTERM)
        except ProcessLookupError: return
        for _ in range(100):
            try: broker.endpoint_request(endpoint,'/health',timeout=.1)
            except Exception: return
            time.sleep(.02)
        self.fail('service did not stop')
    def test_ensure_replaces_an_idle_legacy_process_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            legacy,path=self.start_legacy(directory); endpoint=None
            try:
                env=dict(os.environ,AWB_NATIVE_ROOT=directory)
                script=pathlib.Path(__file__).with_name('native-agent-service.py')
                result=subprocess.run([sys.executable,str(script),'--ensure'],env=env,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stderr,'')
                endpoint=json.loads(result.stdout)
                health=broker.endpoint_request(endpoint,'/health')
                self.assertEqual(health['version'],broker.SERVICE_VERSION)
                # The started service reports the source it is executing, so the next
                # --ensure can tell a deployed change from the running one.
                self.assertEqual(health['implementation'],broker.SOURCE_FINGERPRINT)
                started=broker.datetime.datetime.fromisoformat(health['startedAt'])
                self.assertIsNotNone(started.tzinfo)
                legacy.wait(timeout=2)
            finally:
                try:
                    if endpoint is not None: self.stop_endpoint(endpoint)
                finally:
                    if legacy.poll() is None: legacy.terminate()
                    legacy.wait(timeout=2); legacy.stderr.close()

class SetupTests(unittest.TestCase):
    def result(self, stdout='', code=0):
        return type('Result', (), {'returncode': code, 'stdout': stdout, 'stderr': ''})()

    def test_qoder_reads_live_catalog_without_discovering_omp(self):
        calls = []; catalog = [{'id':'qoder-pro','provider':'vendor','name':'Qoder Pro',
            'thinking':['low','high'],'defaultThinking':'high','isDefault':True,
            '_outerProvider':'PRIVATE-ROUTE','headers':{'Authorization':'PRIVATE'}}]
        def which(binary):
            calls.append(binary)
            return '/fixture/' + binary if binary in ('qoderclicn', 'node') else None
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); package=root/'node_modules'/'@qodercn-ai'/'qodercn-agent-sdk'/'package.json'
            package.parent.mkdir(parents=True); package.write_text('{}')
            with patch.object(broker,'ROOT',root), patch.object(broker.shutil,'which',side_effect=which), \
                 patch.object(broker.subprocess,'run',return_value=self.result('1.1.58')) as run, \
                 patch.object(broker,'qoder_catalog',return_value=catalog) as models:
                status = broker.setup_status('qoder')
        self.assertTrue(status['installed'])
        self.assertNotIn('omp', calls)
        run.assert_called_once_with(['/fixture/qoderclicn','--version'],capture_output=True,text=True,timeout=10)
        models.assert_called_once_with('qoder',live=True)
        self.assertEqual(status['credentialCheck'], 'present')
        self.assertEqual(status['modelCheck'], 'configured')
        self.assertEqual(status['models'], [{'id':'qoder-pro','provider':'vendor','name':'Qoder Pro',
            'thinking':['low','high'],'defaultThinking':'high','isDefault':True}])
        self.assertNotIn('PRIVATE',json.dumps(status))

    def test_omp_rechecks_catalog_and_returns_no_credentials(self):
        catalog = [{'id':'fixture', 'provider':'test', 'name':'Fixture', 'apiKey':'PRIVATE', 'headers':{'Authorization':'PRIVATE'}}]
        with patch.object(broker.shutil, 'which', return_value='/fixture/omp'), patch.object(broker.subprocess, 'run', side_effect=[self.result('18.1.16'), self.result(json.dumps(catalog))]) as run, patch.object(broker, 'MODELS', [{'id':'stale'}]):
            status = broker.setup_status('omp')
        self.assertEqual(status['modelCheck'], 'configured')
        self.assertEqual(status['models'], [{'id':'fixture', 'provider':'test', 'name':'Fixture'}])
        self.assertEqual(run.call_count, 2)
        self.assertNotIn('PRIVATE', json.dumps(status))
        self.assertEqual(status['credentialCheck'], 'unverified')

    def test_omp_18_catalog_envelope_is_shared_by_setup_and_composer(self):
        catalog = {'models':[{'id':'fixture','provider':'test','name':'Fixture','thinking':['high'],
                              'contextWindow':1000,'headers':{'Authorization':'PRIVATE'}}]}
        with patch.object(broker.shutil, 'which', return_value='/fixture/omp'), patch.object(broker.subprocess, 'run', side_effect=[self.result('18.1.16'), self.result(json.dumps(catalog))]):
            status = broker.setup_status('omp')
        self.assertEqual(status['modelCheck'], 'configured')
        self.assertEqual(len(status['models']), 1)
        with patch.object(broker, 'MODELS', None), patch.object(broker, 'dsh_catalog', return_value=[]), patch.object(broker, 'codex_catalog', return_value=[]), patch.object(broker.subprocess, 'run', return_value=self.result(json.dumps(catalog))):
            models = broker.combined_catalog()
        self.assertEqual(models[0]['id'], 'fixture')
        self.assertEqual(models[0]['thinking'], ['high'])
        self.assertNotIn('PRIVATE', json.dumps(models))

    def test_dsh_missing_and_present_credentials_are_distinguished_without_values(self):
        for value, expected in [('', 'missing'), ('fixture-secret-value', 'present')]:
            with patch.object(broker, 'dsh_binary', return_value='/fixture/dsh'), patch.object(broker.subprocess, 'run', return_value=self.result('0.1.5-rc.1')), patch.object(broker, 'dsh_catalog', return_value=[]), patch.dict(os.environ, {'DEEPSEEK_API_KEY':value}):
                status = broker.setup_status('dsh')
            self.assertEqual(status['credentialCheck'], expected)
            self.assertEqual(status['modelCheck'], 'session-handshake')
            self.assertNotIn('fixture-secret-value', json.dumps(status))

    def test_codex_checks_selected_runtime_and_returns_only_catalog_identity(self):
        catalog = [{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['high'],
                    'apiKey':'PRIVATE','headers':{'Authorization':'PRIVATE'}}]
        for credentials in ('present', 'provider-managed'):
            with self.subTest(credentials=credentials), patch.object(broker.shutil, 'which', return_value='/fixture/codex'), \
                 patch.object(broker.subprocess, 'run', return_value=self.result('codex-cli 0.155.1')) as run, \
                 patch.object(broker, 'codex_home', return_value='/fixture/provider-home'), \
                 patch.object(broker, 'codex_credential_status', return_value=credentials) as check, \
                 patch.object(broker, 'codex_catalog', return_value=catalog) as models:
                status = broker.setup_status('codex')
                self.assertEqual(status['credentialCheck'], credentials)
                self.assertEqual(status['modelCheck'], 'configured')
                self.assertEqual(status['models'], [{'id':'gpt-codex','name':'GPT Codex','provider':'codex'}])
                self.assertNotIn('PRIVATE', json.dumps(status))
                check.assert_called_once_with('/fixture/provider-home')
                models.assert_called_once_with('/fixture/provider-home')
                run.assert_called_once_with(['/fixture/codex','--version'], capture_output=True, text=True, timeout=10)

    def test_codex_missing_login_does_not_fetch_catalog(self):
        with patch.object(broker.shutil, 'which', return_value='/fixture/codex'), \
             patch.object(broker.subprocess, 'run', return_value=self.result('codex-cli 0.155.1')), \
             patch.object(broker, 'codex_credential_status', return_value='missing'), \
             patch.object(broker, 'codex_catalog', side_effect=AssertionError('missing login must stop before catalog discovery')):
            status = broker.setup_status('codex')
        self.assertEqual(status['credentialCheck'], 'missing')
        self.assertEqual(status['models'], [])

    def test_missing_runtime_is_not_ready(self):
        with patch.object(broker.shutil, 'which', return_value=None), patch.object(broker.subprocess, 'run') as run:
            self.assertFalse(broker.setup_status('omp')['installed'])
            run.assert_not_called()

    def test_qoderintl_uses_qodercli_and_intl_sdk(self):
        calls = []; catalog=[{'id':'intl-pro','provider':'intl','name':'Intl Pro','thinking':[]}]
        def which(binary):
            calls.append(binary)
            return '/fixture/' + binary if binary in ('qodercli', 'node') else None
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); package=root/'node_modules'/'@qoder-ai'/'qoder-agent-sdk'/'package.json'
            package.parent.mkdir(parents=True); package.write_text('{}')
            with patch.object(broker,'ROOT',root), patch.object(broker.shutil,'which',side_effect=which), \
                 patch.object(broker.subprocess,'run',return_value=self.result('1.1.67')) as run, \
                 patch.object(broker,'qoder_catalog',return_value=catalog) as models:
                status = broker.setup_status('qoderintl')
        self.assertTrue(status['installed'])
        self.assertEqual(run.call_count, 1)
        self.assertNotIn('qoderclicn', calls)
        self.assertTrue(status['sdkInstalled'])
        self.assertEqual(status['modelCheck'], 'configured')
        self.assertEqual(status['credentialCheck'], 'present')
        self.assertEqual(status['models'],catalog)
        models.assert_called_once_with('qoderintl',live=True)
        self.assertEqual(broker.PERMISSION_DEFAULTS['qoderintl'], 'default')

    def test_qoder_catalog_failure_reports_the_matching_login_command(self):
        for provider, cli, sdk in [('qoder','qoderclicn','@qodercn-ai/qodercn-agent-sdk'),
                                   ('qoderintl','qodercli','@qoder-ai/qoder-agent-sdk')]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                root=pathlib.Path(directory); package=root/'node_modules'/sdk/'package.json'
                package.parent.mkdir(parents=True); package.write_text('{}')
                with patch.object(broker,'ROOT',root), patch.object(broker.shutil,'which',side_effect=lambda name:'/fixture/'+name), \
                     patch.object(broker.subprocess,'run',return_value=self.result('1.0')), \
                     patch.object(broker,'qoder_catalog',side_effect=ValueError('not logged in')):
                    status=broker.setup_status(provider)
                self.assertEqual((status['credentialCheck'],status['modelCheck']),('missing','missing'))
                self.assertIn(cli + ' login',status['error'])

    def test_empty_models_and_failed_version_are_not_ready(self):
        with patch.object(broker.shutil, 'which', return_value='/fixture/omp'), patch.object(broker.subprocess, 'run', side_effect=[self.result('18.1.16'), self.result('[]')]):
            self.assertEqual(broker.setup_status('omp')['modelCheck'], 'missing')
        with patch.object(broker.shutil, 'which', return_value='/fixture/omp'), patch.object(broker.subprocess, 'run', return_value=self.result(code=1)):
            self.assertFalse(broker.setup_status('omp')['installed'])

    def test_setup_endpoint_requires_auth_and_does_not_hold_session_lock(self):
        broker.TOKEN = 'fixture-token'
        handler = object.__new__(broker.Handler)
        handler.path = '/setup?provider=qoder'; handler.headers = {'Authorization':'Bearer fixture-token'}
        handler.rfile = io.BytesIO(); responses = []
        handler.respond = lambda status, body: responses.append((status, body))
        def setup(provider):
            acquired = []
            def access_sessions():
                with broker.LOCK: acquired.append(True)
            worker = threading.Thread(target=access_sessions); worker.start(); worker.join(timeout=1)
            self.assertFalse(worker.is_alive(), 'setup must not block active tasks')
            self.assertEqual(provider, 'qoder')
            return {'installed': True}
        with patch.object(broker, 'setup_status', side_effect=setup) as check:
            handler.handle_request(False)
            self.assertEqual(responses[-1], (200, {'installed':True}))
            handler.headers = {}; handler.handle_request(False)
            self.assertEqual(responses[-1][0], 401)
            self.assertEqual(check.call_count, 1)

class IncrementalHistoryTests(unittest.TestCase):
    def session(self, turns=120):
        s = broker.Session(dict(id='paged', provider='omp', title='Paged', cwd='/tmp', model='m',
            busy=False, archived=False, updated=0, revision=0, completed=0, messages=[], interactions=[], error=None))
        s.persist = lambda: None
        for i in range(turns):
            s.upsert({'role':'user','content':'question '+str(i)}, 'u'+str(i))
            s.upsert({'role':'assistant','content':'answer '+str(i)}, 'a'+str(i))
        s.touch()
        return s
    def test_pages_are_whole_turns_and_legacy_is_complete(self):
        s=self.session(); page=s.snapshot(turns='50')
        self.assertEqual(page['history']['start'],140)
        self.assertEqual(page['messages'][0]['id'],'u70')
        all_messages=page['messages']
        while page['history']['start']:
            page=s.snapshot(before=str(page['history']['start']),epoch=page['history']['epoch'],turns='50')
            all_messages=page['messages']+all_messages
        self.assertEqual(all_messages,s.snapshot()['messages'])
        self.assertEqual(len({m['id'] for m in all_messages}),240)
    def test_delta_updates_same_id_and_appends_without_history_copy(self):
        s=self.session(); page=s.snapshot(turns='50'); h=page['history']
        s.upsert({'role':'assistant','content':'changed'},'a119'); s.touch()
        s.upsert({'role':'user','content':'next'},'u120'); s.touch()
        delta=s.snapshot(revision=str(page['revision']),start=str(h['start']),epoch=h['epoch'])
        self.assertEqual(delta['history']['indices'],[239,240])
        self.assertEqual([m['id'] for m in delta['messages']],['a119','u120'])
        self.assertEqual(delta['messages'][0]['content'][0]['text'],'changed')
        delta['messages'][0]['content'][0]['text']='mutated'
        self.assertEqual(s.state['messages'][239]['content'][0]['text'],'changed')
        with patch.object(broker.copy,'deepcopy',side_effect=AssertionError('unchanged must not copy')):
            self.assertEqual(s.snapshot(revision=str(s.state['revision']),start=str(h['start']),epoch=h['epoch']),{'unchanged':True})
    def test_edit_to_older_page_is_reconciled_from_previous_revision(self):
        s=self.session(); first=s.snapshot(turns='50'); h=first['history']
        s.upsert({'role':'assistant','content':'edited old reply'},'a30'); s.touch()
        page=s.snapshot(before=str(h['start']),epoch=h['epoch'],turns='50')
        delta=s.snapshot(revision=str(first['revision']),start=str(page['history']['start']),epoch=h['epoch'])
        self.assertEqual(delta['history']['indices'],[61])
    def test_partial_is_replaced_and_truncated(self):
        s=self.session(); first=s.snapshot(turns='50'); h=first['history']
        s.state['partial']={'role':'assistant','content':[{'type':'text','text':'stream'}]};s.touch()
        delta=s.snapshot(revision=str(first['revision']),start=str(h['start']),epoch=h['epoch'])
        self.assertEqual(delta['history']['indices'],[240]);self.assertEqual(delta['messages'][0]['id'],'live')
        revision=s.state['revision'];s.state.pop('partial');s.touch()
        delta=s.snapshot(revision=str(revision),start=str(h['start']),epoch=h['epoch'])
        self.assertEqual(delta['history']['total'],240);self.assertEqual(delta['messages'],[])
    def test_restart_and_history_reset_cannot_reuse_old_positions(self):
        s=self.session(); page=s.snapshot(turns='50');h=page['history']
        s.state['messages']=[];s.reset_history_index();s.touch()
        reset=s.snapshot(revision=str(page['revision']),start=str(h['start']),epoch=h['epoch'])
        self.assertNotIn('indices',reset['history']);self.assertEqual(reset['messages'],[])
        with self.assertRaises(ValueError):s.snapshot(before='140',epoch=h['epoch'])
    def test_runtime_context_does_not_split_turn_pages(self):
        s=self.session(51)
        for i in range(60):
            s.upsert({'role':'user','content':'<notification id="job">done</notification>'},'note'+str(i))
        s.touch()
        page=s.snapshot(turns='50')
        self.assertEqual(page['messages'][0]['id'],'u1')
        self.assertEqual(page['history']['start'],2)
        s.upsert({'role':'user','content':'actual new prompt'},'note0');s.touch()
        self.assertEqual(len(s.prompt_indices),52)

    def test_nested_runtime_arguments_do_not_alias_stored_messages(self):
        s=self.session(1)
        arguments={'text':'first'}
        event={'role':'assistant','content':[{'type':'toolCall','id':'tool','name':'edit','arguments':arguments}]}
        s.upsert(event,'tool-message');s.touch()
        first=s.snapshot(turns='50');h=first['history']
        arguments['text']='second'
        s.upsert(event,'tool-message');s.touch()
        delta=s.snapshot(revision=str(first['revision']),start=str(h['start']),epoch=h['epoch'])
        self.assertEqual(delta['history']['indices'],[2])
        self.assertEqual(delta['messages'][0]['content'][0]['input']['text'],'second')

    def test_message_versions_are_bounded_by_history_not_token_count(self):
        s=self.session(2)
        for i in range(1000):s.upsert({'role':'assistant','content':str(i)},'a1');s.touch()
        self.assertEqual(len(s.message_versions),4)
        with self.assertRaises(ValueError):s.snapshot(turns='0')
        with self.assertRaises(ValueError):s.snapshot(turns='101')

if __name__=='__main__': unittest.main()
