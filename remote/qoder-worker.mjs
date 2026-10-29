import readline from 'node:readline';
const cfg = JSON.parse(process.argv[2]);
const sdk = await import(cfg.sdk ?? '@qodercn-ai/qodercn-agent-sdk');
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');

if (cfg.operation === 'catalog') {
  const daemon = await sdk.startDaemon({
    auth: sdk.qodercliAuth(), cwd: cfg.cwd,
    pathToQoderCLIExecutable: cfg.binary, initializeTimeoutMs: 45000
  });
  try {
    const account = cfg.accountScoped ? await daemon.accountInfo() : {};
    const uid = typeof account.userId === 'string' && account.userId ? account.userId : undefined;
    emit({type:'models', models:await daemon.getModels({fetchStrategy:'live', ...(uid ? {uid} : {})})});
  } finally {
    await daemon.stop();
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
      if (cmd.type === 'answer') { pending.get(cmd.id)?.(cmd); pending.delete(cmd.id); return; }
      if (cmd.type !== 'prompt' || active) throw new Error('会话正在运行');
      activeTurn = cmd.id;
      const permissionMode = cmd.permissionMode ?? 'default';
      const model = cmd.model ?? cfg.model;
      const parameters = {
        ...(cmd.contextWindow ? {contextWindow:cmd.contextWindow} : {}),
        ...(cmd.thinking ? {reasoningEffort:cmd.thinking} : {}),
        ...(cmd.outerProvider ? {outerProvider:cmd.outerProvider} : {})
      };
      active = sdk.query({prompt: cmd.message, options: {
        auth: sdk.qodercliAuth(), pathToQoderCLIExecutable: cfg.binary, cwd: cfg.cwd,
        permissionMode, includePartialMessages: true, resume,
        ...(permissionMode === 'bypassPermissions' ? {allowDangerouslySkipPermissions: true} : {}),
        ...(model ? {
          model,
          resolveModel: ({purpose}) => ['main','plan'].includes(purpose)
            ? {model, ...(Object.keys(parameters).length ? {parameters} : {})}
            : undefined
        } : {}),
        canUseTool: async (name, input, context) => {
          const id = context.toolUseID;
          const answer = await new Promise(resolve => {
            pending.set(id, resolve);
            context.signal.addEventListener('abort', () => {pending.delete(id); emit({type:'interaction_cancel', id}); resolve({allow:false});}, {once:true});
            emit({type:'interaction', id, name, input, title:context.title, description:context.description});
          });
          if (!answer.allow) return {behavior:'deny', message:'用户拒绝此次操作', toolUseID:id};
          return {behavior:'allow', updatedInput: name === 'AskUserQuestion' ? {...input, answers:answer.answers} : input, toolUseID:id};
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
}
