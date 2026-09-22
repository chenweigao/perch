import importlib.util, io, json, os, pathlib, tempfile, threading, unittest
from unittest.mock import patch

folder=tempfile.TemporaryDirectory(); os.environ['AWB_NATIVE_ROOT']=folder.name
spec=importlib.util.spec_from_file_location('broker',pathlib.Path(__file__).with_name('native-agent-service.py'))
broker=importlib.util.module_from_spec(spec); spec.loader.exec_module(broker)

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
    def test_model_switch_requires_idle_and_both_fields(self):
        s=self.session()
        s.state['busy']=True
        with self.assertRaises(ValueError): self.apply_model(s,{'provider':'openai-codex','model':'gpt-5.4-mini'})
        s.state['busy']=False
        with self.assertRaises(ValueError): self.apply_model(s,{'model':'gpt-5.4-mini'})
        with self.assertRaises(ValueError): self.apply_model(s,{'provider':'openai-codex'})
        self.apply_model(s,{'provider':'openai-codex','model':'gpt-5.4-mini'})
        self.assertEqual(s.state['model'],'gpt-5.4-mini')
        # Qoder has no such command; it must not be silently accepted.
        q=self.session('qoder')
        with self.assertRaises(ValueError): self.apply_model(q,{'provider':'p','model':'m'})
    def apply_model(self,s,body):
        if s.state['provider']!='omp': raise ValueError('当前 Agent 不支持切换模型')
        if s.state['busy']: raise ValueError('请先停止或完成当前任务')
        provider,model=body.get('provider',''),body.get('model','')
        if not provider or not model: raise ValueError('请同时指定 provider 和模型')
        s.state['model']=model; s.state['provider_id']=provider; s.touch(True)
    def test_relaunch_carries_model_and_thinking(self):
        s=self.session(); s.state['model']='gpt-5.4-mini'; s.state['thinking']='xhigh'
        args=['omp','--mode','rpc-ui','--cwd',s.state['cwd']]
        if s.state['model']: args += ['--model',s.state['model']]
        if s.state.get('thinking'): args += ['--thinking',s.state['thinking']]
        self.assertIn('--thinking',args); self.assertEqual(args[args.index('--thinking')+1],'xhigh')
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
    def test_turn_start_steer_and_stream_completion(self):
        s,fake=self.session()
        receipt=s.prompt({'text':'开始','requestId':'request-1'})
        self.assertEqual(receipt['status'],'accepted')
        method,params=next(call for call in fake.calls if call[0]=='turn/start')
        self.assertEqual(params,{'threadId':'native-thread','input':[{'type':'text','text':'开始'}],
                                 'clientUserMessageId':'request-1','model':'gpt-codex','effort':'medium'})
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
        s.codex_frame(fake,{'method':'thread/tokenUsage/updated','params':{'threadId':'native-thread','tokenUsage':{'total':{'totalTokens':1234},'modelContextWindow':200000}}})
        self.assertEqual(s.state['context'],{'tokens':1234,'limit':200000})
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
        self.assertIn('native-thread',broker.SESSIONS)
    def test_create_rejects_model_and_effort_outside_catalog(self):
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium'],'defaultThinking':'medium'}]
        with patch.object(broker,'codex_catalog',return_value=catalog):
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'unknown'})[0],400)
            self.assertEqual(self.request('/sessions',{'provider':'codex','cwd':folder.name,'model':'gpt-codex','thinking':'ultra'})[0],400)
    def test_codex_catalog_discovery_runs_outside_session_lock(self):
        broker.SESSIONS.clear(); fake=FakeCodex(); observed=[]
        catalog=[{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['medium'],'defaultThinking':'medium'}]
        def discover():
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

class SetupTests(unittest.TestCase):
    def result(self, stdout='', code=0):
        return type('Result', (), {'returncode': code, 'stdout': stdout, 'stderr': ''})()

    def test_qoder_does_not_require_or_discover_omp(self):
        calls = []
        def which(binary):
            calls.append(binary)
            return '/fixture/' + binary if binary in ('qoderclicn', 'node') else None
        with patch.object(broker.shutil, 'which', side_effect=which), patch.object(broker.subprocess, 'run', return_value=self.result('1.1.58')) as run:
            status = broker.setup_status('qoder')
        self.assertTrue(status['installed'])
        self.assertNotIn('omp', calls)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(status['credentialCheck'], 'unverified')
        self.assertEqual(status['modelCheck'], 'runtime-default')

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
        with patch.object(broker, 'MODELS', None), patch.object(broker, 'dsh_catalog', return_value=[]), patch.object(broker.subprocess, 'run', return_value=self.result(json.dumps(catalog))):
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

    def test_codex_checks_login_and_returns_only_catalog_identity(self):
        catalog = [{'id':'gpt-codex','provider':'codex','name':'GPT Codex','thinking':['high'],
                    'apiKey':'PRIVATE','headers':{'Authorization':'PRIVATE'}}]
        with patch.object(broker.shutil, 'which', return_value='/fixture/codex'), patch.object(broker.subprocess, 'run', side_effect=[self.result('codex-cli 0.155.1'), self.result('Logged in with a private account')]) as run, patch.object(broker, 'codex_catalog', return_value=catalog):
            status = broker.setup_status('codex')
        self.assertEqual(status['credentialCheck'], 'present')
        self.assertEqual(status['modelCheck'], 'configured')
        self.assertEqual(status['models'], [{'id':'gpt-codex','name':'GPT Codex','provider':'codex'}])
        self.assertNotIn('PRIVATE', json.dumps(status))
        self.assertNotIn('private account', json.dumps(status))
        self.assertEqual(run.call_args_list[1].args[0], ['/fixture/codex','login','status'])

    def test_codex_missing_login_does_not_start_app_server(self):
        with patch.object(broker.shutil, 'which', return_value='/fixture/codex'), patch.object(broker.subprocess, 'run', side_effect=[self.result('codex-cli 0.155.1'), self.result(code=1)]), patch.object(broker, 'codex_catalog', side_effect=AssertionError('login failure must stop before app-server')):
            status = broker.setup_status('codex')
        self.assertEqual(status['credentialCheck'], 'missing')
        self.assertEqual(status['models'], [])

    def test_missing_runtime_is_not_ready(self):
        with patch.object(broker.shutil, 'which', return_value=None), patch.object(broker.subprocess, 'run') as run:
            self.assertFalse(broker.setup_status('omp')['installed'])
            run.assert_not_called()

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

if __name__=='__main__': unittest.main()
