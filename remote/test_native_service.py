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
        # Survivors still say which runtime owns them, so the picker can go on filtering.
        self.assertEqual({e['agent'] for e in payload['models']},{'dsh'})
    def test_combined_catalog_tags_each_runtime(self):
        broker.MODELS=[{'provider':'openai-codex','id':'gpt-5.4-mini','name':'GPT-5.4 mini','selector':'openai-codex/gpt-5.4-mini'}]
        code,payload=self.request('/models')
        self.assertEqual(code,200)
        self.assertEqual([(e['agent'],e['id']) for e in payload['models']],
                         [('omp','gpt-5.4-mini'),('dsh','deepseek-v4-flash'),('dsh','deepseek-v4-pro')])
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

if __name__=='__main__': unittest.main()
