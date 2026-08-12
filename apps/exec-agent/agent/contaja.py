from __future__ import annotations

import re
from pathlib import Path

from playwright.sync_api import Locator, Page, TimeoutError as PlaywrightTimeoutError, sync_playwright

from .adapters.gmail_otp import GmailOtpReader
from .config import ROOT, Settings


class ContajaAgent:
    """Primeiro fluxo do agente: autenticar na ContaJá e chegar à emissão de NFS-e."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.artifacts = ROOT / "var" / "artifacts"
        self.profile = ROOT / "var" / "contaja-browser-profile"
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.profile.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _first_visible(candidates: list[Locator], timeout_ms: int = 1500) -> Locator | None:
        for locator in candidates:
            try:
                locator.first.wait_for(state="visible", timeout=timeout_ms)
                return locator.first
            except PlaywrightTimeoutError:
                pass
        return None

    def _fill_login(self, page: Page) -> None:
        if not self.settings.contaja_email:
            raise RuntimeError("Defina CONTAJA_EMAIL no .env.")

        identifier = self._first_visible([
            page.get_by_label(re.compile(r"e-?mail", re.I)),
            page.get_by_placeholder(re.compile(r"e-?mail", re.I)),
            page.locator('input[type="email"]'),
            page.locator('input[name*="email" i]'),
        ])
        if identifier is None:
            raise RuntimeError("Não encontrei automaticamente o campo de e-mail da ContaJá.")
        identifier.fill(self.settings.contaja_email)

        password = self._first_visible([
            page.get_by_label(re.compile(r"senha", re.I)),
            page.get_by_placeholder(re.compile(r"senha", re.I)),
            page.locator('input[type="password"]'),
        ], timeout_ms=700)
        if password is not None and self.settings.contaja_password:
            password.fill(self.settings.contaja_password)

        submit = self._first_visible([
            page.get_by_role("button", name=re.compile(r"entrar|acessar|continuar|login", re.I)),
            page.locator('button[type="submit"]'),
            page.locator('input[type="submit"]'),
        ])
        if submit is None:
            raise RuntimeError("Não encontrei automaticamente o botão para avançar no login da ContaJá.")
        submit.click()

    def _fill_otp_if_requested(self, page: Page) -> None:
        otp = self._first_visible([
            page.get_by_label(re.compile(r"c[oó]digo|verifica", re.I)),
            page.get_by_placeholder(re.compile(r"c[oó]digo|verifica", re.I)),
            page.locator('input[autocomplete="one-time-code"]'),
        ], timeout_ms=8000)
        if otp is None:
            return

        client_secret = self.settings.gmail_client_secret_path
        if client_secret is None:
            raise RuntimeError("A ContaJá pediu código por e-mail. Defina GMAIL_CLIENT_SECRET_FILE para leitura automática do Gmail.")

        print("ContaJá pediu código. Aguardando o e-mail no Gmail...")
        code = GmailOtpReader(client_secret, self.settings.gmail_token_path).wait_for_code(
            self.settings.contaja_otp_gmail_query,
            timeout_seconds=self.settings.contaja_otp_timeout_seconds,
        )
        otp.fill(code)

        confirm = self._first_visible([
            page.get_by_role("button", name=re.compile(r"confirmar|validar|verificar|continuar|entrar", re.I)),
            page.locator('button[type="submit"]'),
        ])
        if confirm is not None:
            confirm.click()

    @staticmethod
    def _find_invoice_action(page: Page) -> Locator | None:
        candidates = [
            page.get_by_role("button", name=re.compile(r"emitir\s+nf[s-]?e", re.I)),
            page.get_by_role("link", name=re.compile(r"emitir\s+nf[s-]?e", re.I)),
            page.get_by_text(re.compile(r"emitir\s+nf[s-]?e", re.I), exact=False),
            page.get_by_text(re.compile(r"emitir\s+nota\s+fiscal", re.I), exact=False),
        ]
        return ContajaAgent._first_visible(candidates, timeout_ms=2500)

    def login_and_find_invoice(self) -> None:
        with sync_playwright() as playwright:
            context = playwright.chromium.launch_persistent_context(
                str(self.profile),
                headless=self.settings.contaja_headless,
                viewport={"width": 1440, "height": 1000},
            )
            page = context.pages[0] if context.pages else context.new_page()
            try:
                page.goto(self.settings.contaja_base_url, wait_until="domcontentloaded", timeout=45_000)

                if "/dashboard" not in page.url:
                    self._fill_login(page)
                    self._fill_otp_if_requested(page)
                    page.wait_for_load_state("domcontentloaded", timeout=30_000)

                page.screenshot(path=str(self.artifacts / "contaja-after-login.png"), full_page=True)
                action = self._find_invoice_action(page)
                if action is None:
                    raise RuntimeError("Login concluído, mas não encontrei 'Emitir NFS-e' na tela atual.")

                action.scroll_into_view_if_needed()
                action.click()
                page.wait_for_timeout(1200)
                page.screenshot(path=str(self.artifacts / "contaja-emitir-nfse.png"), full_page=True)
                print(f"OK: chegamos à etapa de emissão de NFS-e. URL atual: {page.url}")
                print("O agente para aqui nesta primeira etapa; nenhuma nota é emitida.")
            except Exception:
                page.screenshot(path=str(self.artifacts / "contaja-error.png"), full_page=True)
                raise
            finally:
                context.close()
