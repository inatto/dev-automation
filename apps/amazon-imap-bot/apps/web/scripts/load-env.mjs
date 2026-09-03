import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function parseEnv(filePath) {
    const values = {};
    for (const rawLine of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const separator = line.indexOf('=');
        if (separator <= 0) throw new Error(`Linha inválida em ${filePath}: ${rawLine}`);
        const key = line.slice(0, separator).trim();
        let value = line.slice(separator + 1).trim();
        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
        values[key] = value;
    }
    return values;
}

export function loadConfigEnv() {
    const webRoot = fileURLToPath(new URL('..', import.meta.url));
    const explicit = String(process.env.AMAZON_IMAP_BOT_WEB_ENV || '').trim().toLowerCase();
    const context = explicit || (process.env.NODE_ENV === 'production' ? 'production' : 'local');
    if (!['local', 'production'].includes(context)) throw new Error(`AMAZON_IMAP_BOT_WEB_ENV inválido: ${context}`);
    const filePath = path.join(webRoot, 'config', context, 'app.env');
    if (!fs.existsSync(filePath)) throw new Error(`Configuração Web ausente: ${filePath}`);
    return parseEnv(filePath);
}
