"""Execute the real worker against a local SDK contract stub; never call a model."""
import json, pathlib, queue, shutil, subprocess, tempfile, threading, unittest

@unittest.skipUnless(shutil.which('node'), 'Node is required for the SDK worker contract')
class SubagentWorkerTests(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory(); self.addCleanup(self.folder.cleanup)
        root=pathlib.Path(self.folder.name)
        shutil.copy2(pathlib.Path(__file__).with_name('claude-worker.mjs'),root/'worker.mjs')
        sdk=root/'node_modules/@anthropic-ai/claude-agent-sdk'; sdk.mkdir(parents=True)
        (sdk/'package.json').write_text('{"type":"module","exports":"./index.mjs"}')
        # One approval from inside a subagent and one from the main thread keep the
        # turn open while the test sends stop requests; a child message with its own
        # session id comes last, so a worker that resumed from it would be caught.
        (sdk/'index.mjs').write_text('''export function query({options}) {
 const abort=new AbortController(), stops=[];
 return {
  interrupt:async()=>abort.abort(),
  stopTask:async taskId=>{stops.push(taskId); if(taskId==='missing-task') throw new Error('no such task');},
  async *[Symbol.asyncIterator]() {
   yield {type:'system',subtype:'init',session_id:'main-session',
    options:{forwardSubagentText:options.forwardSubagentText,agentProgressSummaries:options.agentProgressSummaries}};
   const child=await options.canUseTool('Bash',{command:'ls'},{toolUseID:'child-tool',agentID:'agent-1',signal:abort.signal});
   const main=await options.canUseTool('Bash',{command:'pwd'},{toolUseID:'main-tool',signal:abort.signal});
   yield {type:'assistant',session_id:'child-session',parent_tool_use_id:'toolu_agent',message:{role:'assistant',content:[]}};
   yield {type:'result',stops,child,main};
  }
 };
}''')
        cfg={'binary':'fixture','cwd':str(root)}
        if 'forward' in self._testMethodName: cfg['forwardSubagentText']=True
        self.process=subprocess.Popen(['node',str(root/'worker.mjs'),json.dumps(cfg)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(self.close)
        self.events=queue.Queue()
        def read():
            for line in self.process.stdout: self.events.put(json.loads(line))
        threading.Thread(target=read,daemon=True).start()
        self.wait('ready')
        self.send({'type':'prompt','id':'turn-test','message':'派一个子 Agent','permissionMode':'default'})
        self.init=self.wait('system')
        self.child=self.wait('interaction')
    def close(self):
        self.process.terminate(); self.process.communicate(timeout=5)
    def send(self,value):
        self.process.stdin.write(json.dumps(value)+'\n'); self.process.stdin.flush()
    def wait(self,kind):
        while True:
            value=self.events.get(timeout=5)
            if value['type']==kind:return value
    def finish(self):
        self.send({'type':'answer','id':'child-tool','allow':True})
        self.main=self.wait('interaction')
        self.send({'type':'answer','id':'main-tool','allow':True})
        return self.wait('result')
    def test_subagent_text_stays_off_and_summaries_are_not_requested(self):
        self.assertEqual(self.init['options'],{'forwardSubagentText':False})
    def test_forward_flag_from_the_bridge_reaches_the_sdk(self):
        self.assertEqual(self.init['options'],{'forwardSubagentText':True})
    def test_interactions_name_the_subagent_and_main_ones_carry_null(self):
        self.assertEqual((self.child['id'],self.child['agentId']),('child-tool','agent-1'))
        result=self.finish()
        self.assertIn('agentId',self.main); self.assertIsNone(self.main['agentId'])
        self.assertEqual(result['child']['behavior'],'allow'); self.assertEqual(result['main']['behavior'],'allow')
    def test_stop_task_reaches_only_the_active_turn(self):
        self.send({'type':'stop_task','taskId':'task-1','turnId':'other-turn'})
        rejected=self.wait('task_stop_result')
        self.assertEqual((rejected['taskId'],rejected['ok']),('task-1',False)); self.assertTrue(rejected['error'])
        self.send({'type':'stop_task','taskId':'task-1','turnId':'turn-test'})
        self.assertEqual(self.wait('task_stop_result'),{'type':'task_stop_result','taskId':'task-1','ok':True})
        self.send({'type':'stop_task','taskId':'missing-task','turnId':'turn-test'})
        self.assertEqual(self.wait('task_stop_result'),{'type':'task_stop_result','taskId':'missing-task','ok':False,'error':'no such task'})
        # The other turn's request never reached the SDK.
        self.assertEqual(self.finish()['stops'],['task-1','missing-task'])
        self.wait('agent_end')
        self.send({'type':'stop_task','taskId':'task-1','turnId':'turn-test'})
        self.assertFalse(self.wait('task_stop_result')['ok'])
    def test_resume_comes_from_main_thread_messages_only(self):
        self.finish()
        self.assertEqual(self.wait('agent_end')['resume'],'main-session')

if __name__=='__main__': unittest.main()
