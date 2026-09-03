import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const page = fs.readFileSync(path.join(root,'src/pages/index.astro'),'utf8');
const js = fs.readFileSync(path.join(root,'src/scripts/app.js'),'utf8');
const css = fs.readFileSync(path.join(root,'src/styles/global.css'),'utf8');
test('web cobre as funções operacionais',()=>{ for(const token of ['Entrada','Respostas','API / Agente','Console','Funções','Contas','Envio a clientes','Gerar / refazer resposta','Selecionar arquivos']) assert.ok(page.includes(token), token); });
test('ações principais estão ligadas à API',()=>{ for(const token of ['/v1/messages','/reply','/approve','/no-reply','/v1/external-delivery','/v1/actions/refresh','/v1/context-files']) assert.ok(js.includes(token), token); });
test('versão fica visível no canto',()=>{ assert.ok(page.includes('versionBadge')); assert.ok(css.includes('position:fixed')); assert.ok(js.includes('/version')); });

test('polling web é single-flight e não usa setInterval',()=>{ assert.ok(js.includes('refreshInFlight')); assert.ok(js.includes('setTimeout(poll,5000)')); assert.ok(!js.includes('setInterval(()=>refreshView')); });

test('geração acompanha action até concluir ou falhar',()=>{ assert.ok(js.includes('waitForAction')); assert.ok(js.includes('/v1/actions/${encodeURIComponent(actionId)}')); assert.ok(js.includes("done.status==='error'")); });
test('API agente mostra fila e permite nova resposta manual após SENT',()=>{ assert.ok(page.includes('Fila do agente')); assert.ok(page.includes('agentQueue')); assert.ok(js.includes("status==='replied'")); assert.ok(js.includes('Gerar novamente')); assert.ok(!js.includes("status==='replied'?'Já enviada'")); });
