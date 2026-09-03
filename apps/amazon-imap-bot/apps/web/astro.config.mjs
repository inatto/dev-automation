import { defineConfig } from 'astro/config';
import node from '@astrojs/node';
import { loadConfigEnv } from './scripts/load-env.mjs';

const fileEnv = loadConfigEnv();
Object.assign(process.env, fileEnv);
const env = { ...process.env, ...fileEnv };
const port = Number(env.APP_PORT || 4115);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('APP_PORT inválido');

export default defineConfig({
    output: 'server',
    adapter: node({ mode: 'standalone' }),
    devToolbar: { enabled: false },
    server: { host: env.APP_HOST || '127.0.0.1', port },
    vite: {
        define: { 'import.meta.env.API_INTERNAL_URL': JSON.stringify(env.API_INTERNAL_URL || 'http://127.0.0.1:8115') },
        server: { strictPort: true, hmr: false, ws: false, forwardConsole: false },
    },
});
