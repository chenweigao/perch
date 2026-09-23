import {query} from '@anthropic-ai/claude-agent-sdk';
import readline from 'node:readline';
const cfg = JSON.parse(process.argv[2]);
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
let active, activeTurn, resume = cfg.resume, pending = new Map();
readline.createInterface({input: process.stdin}).on('line', async line => {
  let cmd;
  try {
    cmd = JSON.parse(line);
    if (cmd.type === 'abort') {
      const target = active;
      if (target && cmd.turnId === activeTurn) {
        await target.interrupt();
        if (active === target) emit({type:'stop_ack', turnId:cmd.turnId});
      }
      return;
    }
    if (cmd.type === 'answer') { pending.get(cmd.id)?.(cmd); pending.delete(cmd.id); return; }
    if (cmd.type !== 'prompt' || active) throw new Error('会话正在运行');
    activeTurn = cmd.id;
    const permissionMode = cmd.permissionMode ?? 'default';
    active = query({prompt: cmd.message, options: {
      pathToClaudeCodeExecutable: cfg.binary, cwd: cfg.cwd,
      permissionMode, includePartialMessages: true, resume,
      ...(permissionMode === 'bypassPermissions' ? {allowDangerouslySkipPermissions: true} : {}),
      ...(cfg.model ? {model: cfg.model} : {}),
      canUseTool: async (name, input, context) => {
        const id = context.toolUseID;
        const answer = await new Promise(resolve => {
          pending.set(id, resolve);
          context.signal.addEventListener('abort', () => {pending.delete(id); emit({type:'interaction_cancel', id}); resolve({allow:false});}, {once:true});
          emit({type:'interaction', id, name, input, title:context.decisionReason});
        });
        if (!answer.allow) return {behavior:'deny', message:'用户拒绝此次操作'};
        return {behavior:'allow', updatedInput: name === 'AskUserQuestion' ? {...input, answers:answer.answers} : input};
      }
    }});
    emit({type:'agent_start'});
    try {
      for await (const message of active) {
        if (message.session_id) resume = message.session_id;
        emit(message);
      }
    } catch (error) {emit({type:'worker_error', message:error.message});}
    finally {active = null; activeTurn = null; pending.clear(); emit({type:'agent_end', resume});}
  } catch (error) {
    emit({type:'worker_error', message:error.message});
    if (cmd?.type === 'prompt' && !active) emit({type:'agent_end', resume});
  }
});
emit({type:'ready'});
