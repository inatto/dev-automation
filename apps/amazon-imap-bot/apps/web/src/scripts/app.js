const API = '/api';
const state = { view: 'overview', overview: null, inbox: [], replies: [], actions: [], selectedMessage: null, composeTarget: null, selectedFiles: new Set(), filePath: '' };
const $ = (id) => document.getElementById(id);
const esc = (value='') => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));

async function api(path, options={}) {
  const response = await fetch(`${API}${path}`, { headers: { 'content-type':'application/json', ...(options.headers||{}) }, cache:'no-store', ...options });
  const data = await response.json().catch(()=>({}));
  if (!response.ok) throw new Error(data.detail || data.error || `HTTP ${response.status}`);
  return data;
}
function toast(message, type='success') { const node=document.createElement('div'); node.className=`toast ${type}`; node.textContent=message; $('toastHost').append(node); setTimeout(()=>node.remove(), 4200); }
const sleep=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));
async function waitForAction(actionId,{timeoutMs=300000}={}){
  const started=Date.now();
  while(Date.now()-started<timeoutMs){
    const action=await api(`/v1/actions/${encodeURIComponent(actionId)}`);
    if(action.status==='completed'||action.status==='error') return action;
    if(state.view==='api') await loadAgentQueue();
    await sleep(650);
  }
  throw new Error('A geração continuou além do tempo de acompanhamento da página. Consulte API / Agente.');
}
function chip(status='') { const s=String(status||'').toLowerCase(); const cls=s.includes('error')||s.includes('erro')?'bad':s.includes('pending')||s.includes('aguard')||s.includes('queued')||s.includes('bloq')?'warn':s.includes('sent')||s.includes('replied')||s.includes('concl')||s.includes('respond')?'good':'info'; return `<span class="status-chip ${cls}">${esc(status||'—')}</span>`; }
function fmtDate(value) { if(!value) return '—'; const d=new Date(String(value).replace(' ','T')); return Number.isNaN(d.getTime())?esc(value):d.toLocaleString('pt-BR',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}); }
function setView(view) { state.view=view; document.querySelectorAll('.view').forEach(n=>n.classList.toggle('active',n.id===`view-${view}`)); document.querySelectorAll('.nav-item').forEach(n=>n.classList.toggle('active',n.dataset.view===view)); const labels={overview:['Visão geral','Operação, IMAP, respostas e API em uma única visão.'],inbox:['Entrada','Espelho fiel da pasta IMAP original.'],replies:['Respostas','Rascunhos gerados, aprovação e estado de envio.'],api:['API / Agente','Execuções OpenAI e testes ZIP.'],console:['Console','Eventos e diagnósticos persistidos no Oracle.'],functions:['Funções','Catálogo relacional de funções e permissões.'],accounts:['Contas','Estado das caixas IMAP monitoradas.']}; $('pageTitle').textContent=labels[view][0]; $('pageDescription').textContent=labels[view][1]; refreshView(true); }

document.querySelectorAll('.nav-item').forEach(btn=>btn.addEventListener('click',()=>setView(btn.dataset.view)));
document.querySelectorAll('[data-close]').forEach(btn=>btn.addEventListener('click',()=>$(btn.dataset.close).close()));

async function loadOverview() {
  const o=await api('/v1/overview'); state.overview=o;
  $('metricOnline').textContent=`${o.online_accounts}/${o.account_count}`; $('metricAccounts').textContent=o.account_errors?`${o.account_errors} conta(s) com erro`:'sem erros de conta';
  $('metricReceived').textContent=o.received; $('metricPending').textContent=o.pending_approvals; $('metricReplied').textContent=o.replied;
  $('navInboxCount').textContent=o.received; $('navPendingCount').textContent=o.pending_approvals;
  $('cfgModel').textContent=o.model; $('cfgReasoning').textContent=o.reasoning; $('cfgPoll').textContent=`${o.poll_seconds}s`; $('cfgImap').textContent=`${o.imap_host} / ${o.imap_folder}`;
  $('globalDeliveryToggle').checked=!!o.external_send_enabled; $('globalDeliveryText').textContent=o.external_send_enabled?'Liberado':'Bloqueado';
  $('sidebarDot').classList.toggle('online',o.online_accounts>0 && !o.account_errors); $('sidebarStatus').textContent=o.account_errors?'Atenção necessária':`${o.online_accounts}/${o.account_count} caixa(s) online`;
}
function actionText(a){
  if(a.error)return a.error;
  if(a.result&&typeof a.result==='object')return `mensagem=${a.result.inbound_id||'—'} · resposta=${a.result.outbound_id||'—'} · api=#${a.result.api_run_id||'—'}`;
  return a.detail||a.result||'—';
}
function renderActionsInto(node,limit=14){node.innerHTML=state.actions.length?state.actions.slice(0,limit).map(a=>`<div class="activity-item"><strong>${esc(a.kind)}</strong><span title="${esc(actionText(a))}">${esc(actionText(a))}</span>${chip(a.status)}</div>`).join(''):'<div class="empty">Nenhuma ação recente.</div>';}
async function loadActions() { state.actions=await api('/v1/actions'); renderActionsInto($('actionsList'),14); }
async function loadAgentQueue(){state.actions=await api('/v1/actions');renderActionsInto($('agentQueue'),20);}

function messageActions(row, direction) {
  const id=Number(row.id); const status=String(row.status||'').toLowerCase();
  if(direction==='in') {
    const sendingNow=status==='sending'||status==='reply-queued';
    const noReply=status==='no-reply';
    const generateLabel=status==='replied'?'Gerar novamente':sendingNow?'Em envio':noReply?'Bloqueada':'Gerar';
    const generateButton=(sendingNow||noReply)
      ? `<button class="row-action" disabled title="${noReply?'Mensagem marcada como NÃO RESPONDER.':'Resposta já entrou no fluxo de envio; aguarde terminar.'}">${generateLabel}</button>`
      : `<button class="row-action" data-compose="${id}">${generateLabel}</button>`;
    return `<div class="row-actions"><button class="row-action" data-open-message="${id}">Abrir</button>${generateButton}<button class="row-action" data-no-reply="${id}">Não responder</button><button class="row-action danger" data-delete="${id}">Remover</button></div>`;
  }
  const approve = status==='pending-approval'?`<button class="row-action" data-approve="${id}">Liberar</button>`:'';
  const rewrite = ['send-queued','sending','sent'].includes(status)?'':`<button class="row-action" data-compose="${id}">Refazer</button>`;
  return `<div class="row-actions"><button class="row-action" data-open-message="${id}">Abrir</button>${rewrite}${approve}</div>`;
}
function wireTableActions() {
  document.querySelectorAll('[data-open-message]').forEach(b=>b.onclick=()=>openMessage(Number(b.dataset.openMessage)));
  document.querySelectorAll('[data-compose]').forEach(b=>b.onclick=()=>openCompose(Number(b.dataset.compose)));
  document.querySelectorAll('[data-approve]').forEach(b=>b.onclick=()=>approve(Number(b.dataset.approve)));
  document.querySelectorAll('[data-no-reply]').forEach(b=>b.onclick=()=>noReply(Number(b.dataset.noReply)));
  document.querySelectorAll('[data-delete]').forEach(b=>b.onclick=()=>removeMessage(Number(b.dataset.delete)));
}
async function loadInbox() { state.inbox=await api('/v1/messages?direction=in&limit=1000'); renderInbox(); }
function renderInbox() { const q=$('inboxSearch').value.toLowerCase(); const rows=state.inbox.filter(r=>`${r.sender||''} ${r.subject||''} ${r.status||''}`.toLowerCase().includes(q)); $('inboxSummary').textContent=`${rows.length} de ${state.inbox.length} mensagens`; $('inboxBody').innerHTML=rows.map(r=>`<tr><td>${fmtDate(r.mail_date||r.created_at)}</td><td>${esc(r.sender||'—')}</td><td class="subject-cell" title="${esc(r.subject||'')}">${esc(r.subject||'(sem assunto)')}</td><td>${chip(r.status)}</td><td class="actions-col">${messageActions(r,'in')}</td></tr>`).join('')||'<tr><td colspan="5" class="empty">Nenhuma mensagem.</td></tr>'; wireTableActions(); }
async function loadReplies() { state.replies=await api('/v1/messages?direction=out&limit=1000'); renderReplies(); }
function renderReplies() { const q=$('replySearch').value.toLowerCase(); const rows=state.replies.filter(r=>`${r.recipient||''} ${r.subject||''} ${r.status||''}`.toLowerCase().includes(q)); $('replySummary').textContent=`${rows.length} de ${state.replies.length} respostas`; $('replyBody').innerHTML=rows.map(r=>`<tr><td>${fmtDate(r.created_at)}</td><td>${esc(r.recipient||'—')}</td><td class="subject-cell" title="${esc(r.subject||'')}">${esc(r.subject||'(sem assunto)')}</td><td>${chip(r.status)}</td><td>${esc(r.recipient_class||'—')}</td><td class="actions-col">${messageActions(r,'out')}</td></tr>`).join('')||'<tr><td colspan="6" class="empty">Nenhuma resposta.</td></tr>'; wireTableActions(); }
$('inboxSearch').addEventListener('input',renderInbox); $('replySearch').addEventListener('input',renderReplies);

async function openMessage(id) { try { const r=await api(`/v1/messages/${id}`); state.selectedMessage=r; $('messageDirection').textContent=r.direction==='in'?'ENTRADA':'RESPOSTA'; $('messageTitle').textContent=r.subject||'(sem assunto)'; $('messageMeta').innerHTML=`<div><b>Remetente</b>${esc(r.sender||'—')}</div><div><b>Destinatário</b>${esc(r.recipient||'—')}</div><div><b>Status</b>${esc(r.status||'—')}</div><div><b>Data</b>${fmtDate(r.mail_date||r.created_at)}</div>`; $('messageBody').textContent=r.body||''; const dir=r.direction; $('messageActions').innerHTML=dir==='in'?`<button class="button secondary" data-close-local>Fechar</button><button class="button secondary" id="detailNoReply">Não responder</button><button class="button primary" id="detailCompose">${String(r.status||'').toLowerCase()==='replied'?'Gerar nova resposta':'Gerar resposta'}</button>`:`<button class="button secondary" data-close-local>Fechar</button>${String(r.status).toLowerCase()==='pending-approval'?'<button class="button primary" id="detailApprove">Liberar envio</button>':''}`; $('messageActions').querySelector('[data-close-local]').onclick=()=>$('messageDialog').close(); if($('detailCompose')) $('detailCompose').onclick=()=>{ $('messageDialog').close(); openCompose(id); }; if($('detailNoReply')) $('detailNoReply').onclick=()=>noReply(id); if($('detailApprove')) $('detailApprove').onclick=()=>approve(id); $('messageDialog').showModal(); } catch(e){toast(e.message,'error')} }
async function openCompose(id) { try { const r=await api(`/v1/messages/${id}`); state.composeTarget=r; state.selectedFiles.clear(); $('replyInstruction').value=''; renderSelectedFiles(); $('replyDialog').showModal(); } catch(e){toast(e.message,'error')} }
$('generateReplyButton').onclick=async()=>{
  const row=state.composeTarget;if(!row)return;
  $('generateReplyButton').disabled=true;
  try{
    const a=await api(`/v1/messages/${row.id}/reply`,{method:'POST',body:JSON.stringify({instruction:$('replyInstruction').value,files:[...state.selectedFiles]})});
    $('replyDialog').close();
    toast(`Geração enfileirada (${a.id.slice(0,8)}). Acompanhando execução…`);
    if(state.view==='api') await loadAgentQueue();
    const done=await waitForAction(a.id);
    if(done.status==='error') throw new Error(done.error||'Falha ao gerar resposta.');
    const result=done.result&&typeof done.result==='object'?done.result:{};
    toast(`Resposta gerada${result.outbound_id?` (#${result.outbound_id})`:''}.`);
    await loadOverview();
    await loadReplies();
    await loadApiRuns();
    setView('replies');
    if(result.outbound_id){ await openMessage(Number(result.outbound_id)); }
  }catch(e){toast(e.message,'error');await refreshView(true)}finally{$('generateReplyButton').disabled=false;}
};
async function approve(id){ try{await api(`/v1/messages/${id}/approve`,{method:'POST',body:'{}'}); toast('Resposta liberada.'); $('messageDialog').close(); await refreshView(true);}catch(e){toast(e.message,'error')} }
async function noReply(id){ if(!confirm('Marcar este e-mail como NÃO RESPONDER? Respostas pendentes serão canceladas.'))return; try{await api(`/v1/messages/${id}/no-reply`,{method:'POST',body:'{}'}); toast('Marcado como NÃO RESPONDER.'); $('messageDialog').close(); await refreshView(true);}catch(e){toast(e.message,'error')} }
async function removeMessage(id){ if(!confirm('Remover esta mensagem também do IMAP? A remoção entra em fila assíncrona.'))return; try{const r=await api(`/v1/messages/${id}`,{method:'DELETE'}); toast(`Remoção enfileirada. Pendentes: ${r.pending_deletes}`); await refreshView(true);}catch(e){toast(e.message,'error')} }

$('globalDeliveryToggle').addEventListener('change',async(e)=>{ const enabled=e.target.checked; try{const r=await api('/v1/external-delivery',{method:'PUT',body:JSON.stringify({enabled})}); toast(enabled?`Envio global liberado. ${r.activated||0} resposta(s) enfileirada(s).`:'Envio global bloqueado.'); await loadOverview();}catch(err){e.target.checked=!enabled;toast(err.message,'error')} });
$('refreshButton').onclick=async()=>{ try{await api('/v1/actions/refresh',{method:'POST',body:'{}'});toast('Atualização IMAP enfileirada.');}catch(e){toast(e.message,'error')} };

async function browseFiles(path=''){ try{state.filePath=path;const data=await api(`/v1/context-files?path=${encodeURIComponent(path)}`);$('filePath').textContent=`Code/${path}`;$('fileBackButton').disabled=!data.parent;$('fileBackButton').dataset.parent=data.parent||'';$('fileList').innerHTML=(data.entries||[]).map(item=>{const selected=state.selectedFiles.has(item.path);return `<button class="file-row ${selected?'selected':''}" data-file-path="${esc(item.path)}" data-file-type="${esc(item.type)}"><span>${item.type==='dir'?'▣':'▤'}</span><span>${esc(item.name)}</span><small>${item.type==='file'?`${item.size||0} B`:'pasta'}</small></button>`}).join('')||'<div class="empty">Pasta vazia.</div>';document.querySelectorAll('.file-row').forEach(b=>b.onclick=()=>{const path=b.dataset.filePath;if(b.dataset.fileType==='dir')browseFiles(path);else{state.selectedFiles.has(path)?state.selectedFiles.delete(path):state.selectedFiles.size<8?state.selectedFiles.add(path):toast('Máximo de 8 arquivos.','error');browseFiles(state.filePath);}});}catch(e){toast(e.message,'error')} }
$('chooseFilesButton').onclick=()=>{browseFiles('');$('fileDialog').showModal();}; $('fileBackButton').onclick=()=>browseFiles($('fileBackButton').dataset.parent||''); $('fileConfirmButton').onclick=()=>{$('fileDialog').close();renderSelectedFiles();};
function renderSelectedFiles(){$('selectedFiles').innerHTML=state.selectedFiles.size?[...state.selectedFiles].map(f=>`<span class="selected-file">${esc(f)}</span>`).join(''):'<span>Nenhum arquivo selecionado.</span>';}

async function loadApiRuns(){await loadAgentQueue();const rows=await api('/v1/api-runs?limit=300');$('apiRunsBody').innerHTML=rows.map(r=>`<tr data-api-run="${r.id}"><td>#${r.id}</td><td>${esc(r.kind)}</td><td>${fmtDate(r.started_at)}</td><td>${chip(r.status)}</td><td>${esc(r.model)}</td><td>${esc(r.reasoning_effort||'—')}</td><td>${r.elapsed_ms?`${(r.elapsed_ms/1000).toFixed(1)}s`:'—'}</td></tr>`).join('')||'<tr><td colspan="7" class="empty">Nenhuma execução.</td></tr>';document.querySelectorAll('[data-api-run]').forEach(row=>row.onclick=()=>openApiRun(Number(row.dataset.apiRun)));}
async function openApiRun(id){try{const r=await api(`/v1/api-runs/${id}`);$('apiRunTitle').textContent=`#${r.id} · ${r.kind||'API'}`;$('apiRunMeta').innerHTML=`<div><b>Status</b>${esc(r.status||'—')}</div><div><b>Modelo</b>${esc(r.model||'—')}</div><div><b>Raciocínio</b>${esc(r.reasoning_effort||'—')}</div><div><b>Tempo</b>${r.elapsed_ms?`${(r.elapsed_ms/1000).toFixed(2)}s`:'—'}</div>`;$('apiRunRequest').textContent=r.request_payload||r.request_summary||'';$('apiRunResponse').textContent=r.error||r.error_message||r.response_summary||r.output_path||'';$('apiRunDialog').showModal();}catch(e){toast(e.message,'error')}}
$('zipTestButton').onclick=()=>$('zipDialog').showModal(); $('runZipButton').onclick=async()=>{try{const a=await api('/v1/actions/api-zip-test',{method:'POST',body:JSON.stringify({reasoning_effort:$('zipReasoning').value,request_text:$('zipRequest').value})});$('zipDialog').close();toast(`Teste ZIP enfileirado (${a.id.slice(0,8)})`);await loadApiRuns();}catch(e){toast(e.message,'error')}};
async function loadConsole(){const rows=await api('/v1/events?limit=1000');$('consoleBody').innerHTML=rows.map(r=>`<div class="console-line ${String(r.level||'').toLowerCase()==='error'?'error':''}"><span class="time">${esc(r.created_at||'')}</span><span class="cat">${esc(r.category||'')}</span><span>${esc(r.level||'')}</span><span class="text">${esc(r.text||r.event_text||'')}</span></div>`).join('')||'<div class="empty">Sem eventos.</div>'; $('consoleBody').scrollTop=$('consoleBody').scrollHeight;} $('consoleRefresh').onclick=loadConsole;
async function loadFunctions(){const p=await api('/v1/functions');const map=p.functions||{};const funcs=Object.entries(map).map(([name,value])=>({name,...value}));$('functionSummary').textContent=`versão ${p.version||'—'} · ${funcs.length} função(ões)`;$('functionsGrid').innerHTML=funcs.map(f=>{const props=Object.keys((f.parameters&&f.parameters.properties)||{});return `<article class="function-card"><h3>${esc(f.name)}</h3><p>${esc(f.description||'')}</p><div class="tags">${(f.allowed_reasoning_levels||[]).map(x=>`<span class="tag">nível ${esc(x)}</span>`).join('')}${props.map(x=>`<span class="tag">${esc(x)}</span>`).join('')}</div></article>`}).join('')||'<div class="empty">Nenhuma função ativa.</div>';}
$('functionsSync').onclick=async()=>{try{await api('/v1/actions/functions-sync',{method:'POST',body:'{}'});toast('Recarga do catálogo enfileirada.');setTimeout(loadFunctions,800);}catch(e){toast(e.message,'error')}};
async function loadAccounts(){const rows=await api('/v1/accounts');$('accountsGrid').innerHTML=rows.map(a=>`<article class="account-card"><h3>${esc(a.email)}</h3><p>${a.connected?'Online':'Offline'} · última checagem ${esc(a.last_check||'—')}</p><div class="tags"><span class="status-chip ${a.connected?'good':'bad'}">${a.connected?'online':'offline'}</span><span class="tag">recebidos ${a.received}</span><span class="tag">respondidos ${a.replied}</span></div>${a.last_error?`<p style="margin-top:10px;color:#b42318">${esc(a.last_error)}</p>`:''}</article>`).join('')||'<div class="empty">Nenhuma conta ativa.</div>';}

let refreshInFlight=false;
async function refreshView(force=false){
  if(refreshInFlight&&!force)return;
  refreshInFlight=true;
  try{await loadOverview();if(state.view==='overview'){await loadActions();}else if(state.view==='inbox'){await loadInbox();}else if(state.view==='replies'){await loadReplies();}else if(state.view==='api'){await loadApiRuns();}else if(state.view==='console'){await loadConsole();}else if(state.view==='functions'&&force){await loadFunctions();}else if(state.view==='accounts'){await loadAccounts();}}catch(e){$('sidebarStatus').textContent='API indisponível';$('sidebarDot').classList.remove('online');if(force)toast(e.message,'error')}finally{refreshInFlight=false;}
}
async function poll(){await refreshView(false);setTimeout(poll,5000);}
async function init(){try{const v=await api('/version');$('versionBadge').textContent=v.version;}catch{$('versionBadge').textContent='versão indisponível'}await refreshView(true);setTimeout(poll,5000);} init();
