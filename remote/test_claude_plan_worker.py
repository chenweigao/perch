"""Execute the real worker against a local SDK contract stub; never call a model."""
import json, pathlib, queue, shutil, subprocess, tempfile, threading, unittest

@unittest.skipUnless(shutil.which('node'), 'Node is required for the SDK worker contract')
class PlanWorkerTests(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory(); self.addCleanup(self.folder.cleanup)
        root=pathlib.Path(self.folder.name)
        shutil.copy2(pathlib.Path(__file__).with_name('claude-worker.mjs'),root/'worker.mjs')
        sdk=root/'node_modules/@anthropic-ai/claude-agent-sdk'; sdk.mkdir(parents=True)
        (sdk/'package.json').write_text('{"type":"module","exports":"./index.mjs"}')
        self.plan_path=root/'.claude/plans/fixture.md'
        file_setup=''
        input_value="{plan:'完整计划 中文'}"
        if '_file_' in self._testMethodName:
            self.plan_path.parent.mkdir(parents=True)
            self.plan_path.write_text('来自本轮计划文件')
            file_setup="await options.hooks.PostToolUse[0].hooks[0]({tool_input:{file_path:"+json.dumps(str(self.plan_path))+"}});"
            input_value="{plan:'stale parsed text'}" if 'stale' in self._testMethodName else '{}'
            if 'subagent' in self._testMethodName:
                other=self.plan_path.with_name('subagent.md'); other.write_text('另一个 Agent 的计划')
                file_setup+="await options.hooks.PostToolUse[0].hooks[0]({agent_id:'child',tool_input:{file_path:"+json.dumps(str(other))+"}});"
        (sdk/'index.mjs').write_text('''export function query({options}) {
 const abort=new AbortController();
 return {
  interrupt:async()=>abort.abort(),
  async *[Symbol.asyncIterator]() {
   '''+file_setup+'''
   const result=await options.canUseTool('ExitPlanMode','''+input_value+''',
    {toolUseID:'plan-tool',signal:abort.signal});
   yield {type:'result',result:JSON.stringify(result)};
  }
 };
}''')
        self.process=subprocess.Popen(['node',str(root/'worker.mjs'),json.dumps({'binary':'fixture','cwd':str(root)})],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(self.close)
        self.events=queue.Queue()
        def read():
            for line in self.process.stdout: self.events.put(json.loads(line))
        threading.Thread(target=read,daemon=True).start()
        self.wait('ready')
        self.send({'type':'prompt','id':'turn-test','message':'计划','permissionMode':'plan'})
        self.interaction=self.wait('interaction')
    def close(self):
        self.process.terminate(); self.process.communicate(timeout=5)
    def send(self,value):
        self.process.stdin.write(json.dumps(value)+'\n'); self.process.stdin.flush()
    def wait(self,kind):
        while True:
            value=self.events.get(timeout=5)
            if value['type']==kind:return value
    def test_feedback_reaches_the_sdk_denial(self):
        self.send({'type':'answer','id':'plan-tool','allow':False,'feedback':'补充验收步骤'})
        result=json.loads(self.wait('result')['result'])
        self.assertEqual(result,{'behavior':'deny','message':'补充验收步骤'})
    def test_approval_preserves_input_and_existing_permissions(self):
        self.send({'type':'answer','id':'plan-tool','allow':True})
        result=json.loads(self.wait('result')['result'])
        self.assertEqual(result,{'behavior':'allow','updatedInput':{'plan':'完整计划 中文'}})
    def test_abort_cancels_the_wait_without_approval(self):
        self.send({'type':'abort','turnId':'turn-test'})
        self.assertEqual(self.wait('interaction_cancel')['id'],'plan-tool')
        self.assertEqual(json.loads(self.wait('result')['result'])['behavior'],'deny')
    def test_file_plan_changes_require_a_new_decision(self):
        self.assertEqual(self.interaction['planContent'],'来自本轮计划文件')
        self.plan_path.write_text('已修改的计划')
        self.send({'type':'answer','id':'plan-tool','allow':True})
        updated=self.wait('interaction')
        self.assertTrue(updated['planChanged']); self.assertEqual(updated['planContent'],'已修改的计划')
        self.send({'type':'answer','id':'plan-tool','allow':True})
        self.assertEqual(json.loads(self.wait('result')['result']),{'behavior':'allow','updatedInput':{}})
    def test_file_plan_removed_requires_revision(self):
        self.plan_path.unlink()
        self.send({'type':'answer','id':'plan-tool','allow':True})
        self.assertEqual(self.wait('interaction')['planContent'],'')
        self.send({'type':'answer','id':'plan-tool','allow':False,'feedback':'请补充完整计划'})
        self.assertEqual(json.loads(self.wait('result')['result'])['message'],'请补充完整计划')
    def test_file_plan_replaces_stale_parsed_text(self):
        self.assertEqual(self.interaction['planContent'],'来自本轮计划文件')
        self.send({'type':'answer','id':'plan-tool','allow':True})
        self.assertEqual(json.loads(self.wait('result')['result'])['updatedInput']['plan'],'来自本轮计划文件')
    def test_file_plan_isolated_from_subagent_writes(self):
        self.assertEqual(self.interaction['planContent'],'来自本轮计划文件')
        self.send({'type':'answer','id':'plan-tool','allow':True})
        self.assertEqual(json.loads(self.wait('result')['result'])['behavior'],'allow')
