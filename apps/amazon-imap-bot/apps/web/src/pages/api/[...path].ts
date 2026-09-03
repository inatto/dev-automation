import type { APIRoute } from 'astro';

export const prerender = false;

const proxy: APIRoute = async ({ request, params }) => {
    const base = String(import.meta.env.API_INTERNAL_URL || 'http://127.0.0.1:8115').replace(/\/$/, '');
    const incoming = new URL(request.url);
    const suffix = String(params.path || '');
    const target = `${base}/api/${suffix}${incoming.search}`;
    const headers = new Headers(request.headers);
    headers.delete('host');
    headers.delete('content-length');
    const init: RequestInit = { method: request.method, headers, redirect: 'manual' };
    if (!['GET', 'HEAD'].includes(request.method)) init.body = await request.arrayBuffer();
    try {
        const response = await fetch(target, init);
        const responseHeaders = new Headers(response.headers);
        responseHeaders.set('cache-control', 'no-store');
        return new Response(response.body, { status: response.status, headers: responseHeaders });
    } catch (error) {
        return new Response(JSON.stringify({ detail: `API indisponível: ${error}` }), {
            status: 502,
            headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
        });
    }
};

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const DELETE = proxy;
export const PATCH = proxy;
export const OPTIONS = proxy;
