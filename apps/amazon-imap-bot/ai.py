from __future__ import annotations

from message import Incoming


SYSTEM = """Você redige APENAS uma confirmação curta de recebimento de e-mail para uma central de suporte.
Responda em português do Brasil, com tom profissional, natural e objetivo.
Você pode agradecer quando fizer sentido pelo conteúdo da mensagem.
Informe somente que a mensagem foi recebida, está sendo verificada/analisada e que haverá retorno.
NÃO resolva o assunto, NÃO dê instruções técnicas, NÃO invente prazo, protocolo, fatos ou providências já concluídas.
NÃO diga que é IA, robô ou resposta automática.
Use de 2 a 4 frases, sem assunto, assinatura, markdown ou saudação excessiva."""


class ReplyGenerator:
    def __init__(self, api_key: str, model: str, base_url: str):
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY ausente e fallback do GPT Console não disponível")
        from openai import OpenAI
        self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=60)
        self.model = model

    def generate(self, item: Incoming) -> str:
        content = item.body.strip() or "(mensagem recebida sem corpo textual)"
        prompt = (
            f"Remetente: {item.sender_name or item.sender_email}\n"
            f"Assunto: {item.subject or '(sem assunto)'}\n"
            f"Mensagem:\n{content}"
        )
        response = self.client.responses.create(
            model=self.model,
            instructions=SYSTEM,
            input=prompt,
        )
        text = str(getattr(response, "output_text", "") or "").strip()
        if not text:
            raise RuntimeError("OpenAI retornou resposta vazia")
        return text
