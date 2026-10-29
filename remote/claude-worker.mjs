import {readFileSync} from 'node:fs';
import {isAbsolute, normalize, sep} from 'node:path';
import readline from 'node:readline';
const cfg = JSON.parse(process.argv[2]);
const {query} = await import(cfg.sdk ?? '@anthropic-ai/claude-agent-sdk');
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');

if (cfg.operation === 'catalog') {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);
  async function* input() { await new Promise(() => {}); }
  const active = query({prompt: input(), options: {
    pathToClaudeCodeExecutable: cfg.binary, cwd: cfg.cwd,
    permissionMode: 'default', abortController: controller
  }});
  try {
    emit({type:'models', models:await active.supportedModels()});
  } finally {
    clearTimeout(timeout);
    active.close();
  }
} else {
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
    if (cmd.type === 'stop_task') {
      // A control request like interrupt(): it may stop a child of the running
      // turn only, and the bridge hears back either way.
      const target = active;
      let error;
      if (target && cmd.turnId === activeTurn) {
        try { await target.stopTask(cmd.taskId); }
        catch (failure) { error = failure?.message || String(failure); }
      } else error = '子 Agent 所在的轮次已结束';
      emit({type:'task_stop_result', taskId:cmd.taskId, ok:!error, ...(error ? {error} : {})});
      return;
    }
    if (cmd.type === 'answer') { pending.get(cmd.id)?.(cmd); pending.delete(cmd.id); return; }
    if (cmd.type !== 'prompt' || active) throw new Error('会话正在运行');
    activeTurn = cmd.id;
    const permissionMode = cmd.permissionMode ?? 'default';
    const attachments = Array.isArray(cmd.attachments) ? cmd.attachments : [];
    let prompt = cmd.message;
    // Track only this query's successful writes to Claude's plan directory.
    // Never choose the newest file from another conversation.
    const writtenPlanPaths = new Map();
    const planPath = value => typeof value === 'string' && isAbsolute(value)
      && normalize(value).includes(`${sep}.claude${sep}plans${sep}`) ? value : undefined;
    const readPlan = (input, agentID) => {
      const path = planPath(input.planFilePath) || writtenPlanPaths.get(agentID ?? "");
      if (path) {
        try { return {path, content:readFileSync(path, 'utf8')}; }
        catch { return {path, content:''}; }
      }
      return {content:typeof input.plan === 'string' ? input.plan : ''};
    };
    if (attachments.length) {
      const content = [];
      let note = '';
      for (const a of attachments) {
        if (/^image\/(png|jpeg|gif|webp)$/.test(a.mediaType || ''))
          content.push({type:'image', source:{type:'base64', media_type:a.mediaType, data:readFileSync(a.path).toString('base64')}});
        else note += `\n[Attached file ${a.name} is saved at ${a.path}; inspect it with the Read tool.]`;
      }
      content.push({type:'text', text: cmd.message + note});
      // Image blocks only travel through streaming input. The CLI replays the
      // streamed message as a user event; the loop below drops replays because
      // the bridge already recorded the prompt with its attachment names.
      prompt = (async function* () { yield {type:'user', message:{role:'user', content}, parent_tool_use_id:null}; })();
    }
    active = query({prompt, options: {
      pathToClaudeCodeExecutable: cfg.binary, cwd: cfg.cwd,
      permissionMode, includePartialMessages: true, resume,
      // Subagent text is only forwarded once the bridge knows it cannot reach the
      // main streaming tail; tool calls and results arrive either way.
      forwardSubagentText: cfg.forwardSubagentText === true,
      ...(permissionMode === 'bypassPermissions' ? {allowDangerouslySkipPermissions: true} : {}),
      ...(cfg.model ? {model: cfg.model} : {}),
      ...(cfg.thinking ? {effort: cfg.thinking} : {}),
      hooks: {PostToolUse:[{matcher:'Write|Edit', hooks:[async event => {
        const path = planPath(event.tool_input?.file_path);
        if (path) writtenPlanPaths.set(event.agent_id ?? "", path);
        return {};
      }]}]},
      canUseTool: async (name, input, context) => {
        const id = context.toolUseID;
        let changed = false;
        while (true) {
          if (context.signal.aborted) return {behavior:'deny', message:'操作已取消'};
          const plan = name === 'ExitPlanMode' ? readPlan(input, context.agentID) : undefined;
          let onAbort;
          const answer = await new Promise(resolve => {
            pending.set(id, resolve);
            onAbort = () => {pending.delete(id); emit({type:'interaction_cancel', id}); resolve({allow:false});};
            context.signal.addEventListener('abort', onAbort, {once:true});
            emit({type:'interaction', id, name, input, title:context.decisionReason, agentId:context.agentID ?? null,
              ...(plan ? {planContent:plan.content, planChanged:changed} : {})});
          });
          context.signal.removeEventListener('abort', onAbort);
          if (context.signal.aborted) return {behavior:'deny', message:'操作已取消'};
          if (plan && answer.allow) {
            const current = readPlan(input, context.agentID);
            if (!plan.content.trim() || current.content !== plan.content || current.path !== plan.path) {
              changed = true;
              continue;
            }
          }
          if (!answer.allow) return {behavior:'deny', message:answer.feedback || '用户拒绝此次操作'};
          return {behavior:'allow', updatedInput: name === 'AskUserQuestion' ? {...input, answers:answer.answers}
            : plan && typeof input.plan === 'string' ? {...input, plan:plan.content} : input};
        }
      }
    }});
    emit({type:'agent_start'});
    try {
      for await (const message of active) {
        if (message.isReplay) continue;
        // Only the main thread names the session to resume; a child must not.
        if (message.session_id && !message.parent_tool_use_id) resume = message.session_id;
        emit(message);
        if (message.type === 'result') {
          // result.usage totals every API request of the turn, and modelUsage's
          // contextWindow is the model's declared limit — neither is the resolved
          // autocompact window (e.g. the 200K policy boundary on 1M models). The
          // control reply carries both real numbers; keep the emitted result
          // readings as the fallback when an older CLI cannot answer.
          try {
            const usage = await Promise.race([
              active.getContextUsage({detail:'summary'}),
              new Promise((_, reject) => setTimeout(() => reject(new Error('getContextUsage timeout')), 3000)),
            ]);
            if (usage?.raw_max_tokens) emit({type:'context_usage', model:usage.model,
              tokens:usage.total_tokens, limit:usage.raw_max_tokens});
          } catch {}
        }
      }
    } catch (error) {emit({type:'worker_error', message:error.message});}
    finally {active = null; activeTurn = null; pending.clear(); emit({type:'agent_end', resume});}
  } catch (error) {
    emit({type:'worker_error', message:error.message});
    if (cmd?.type === 'prompt' && !active) emit({type:'agent_end', resume});
  }
});
emit({type:'ready'});
}
