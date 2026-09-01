from __future__ import annotations

from dataclasses import dataclass
from function_map import FunctionMap, FunctionRequest


ROUTER_INSTRUCTIONS = """Você é exclusivamente um roteador de funções para e-mails recebidos.
Analise semanticamente o que o remetente está pedindo, sem depender de frase exata, palavra-chave ou alias.
As únicas funções que você pode escolher são as ferramentas fornecidas nesta chamada; elas já foram filtradas pelas permissões locais do remetente.
Se o pedido corresponder claramente a uma função disponível, chame exatamente essa função e extraia os argumentos do texto.
Se não corresponder a nenhuma função disponível, NÃO chame ferramenta.
Nunca invente autorização, função, parâmetro ou nível.
Para níveis de raciocínio use exatamente: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max.
Você apenas escolhe a função e os argumentos. A execução e uma segunda validação de segurança acontecem no Python local."""


@dataclass(frozen=True)
class RouteResult:
    request: FunctionRequest | None
    response_id: str
    selected_name: str


class FunctionRouter:
    def __init__(
        self,
        api_key: str,
        model: str,
        base_url: str,
        timeout_seconds: int,
        function_map: FunctionMap,
        client=None,
    ):
        if client is None:
            if not api_key:
                raise RuntimeError("OPENAI_API_KEY ausente")
            from openai import OpenAI
            client = OpenAI(api_key=api_key, base_url=base_url, timeout=timeout_seconds)
        self.client = client
        self.model = model
        self.function_map = function_map
        self.reasoning_effort = "low"

    @staticmethod
    def _output_items(response) -> list:
        output = getattr(response, "output", None)
        if isinstance(output, list):
            return output
        if output is None:
            return []
        try:
            return list(output)
        except TypeError:
            return []

    @staticmethod
    def build_prompt(sender: str, subject: str, body: str) -> str:
        content = str(body or "").strip() or "(mensagem sem corpo textual)"
        return (
            f"Remetente: {sender}\n"
            f"Assunto: {subject or '(sem assunto)'}\n"
            "Mensagem:\n---\n"
            f"{content}\n"
            "---"
        )

    def audit_payload(self, sender: str, subject: str, body: str) -> str:
        tools = self.function_map.openai_tools_for_sender(sender)
        prompt = self.build_prompt(sender, subject, body)
        tool_lines: list[str] = []
        for tool in tools:
            name = str(tool.get("name") or "-")
            description = str(tool.get("description") or "").strip()
            tool_lines.append(f"FUNÇÃO: {name}")
            if description:
                tool_lines.append(f"Descrição: {description}")
            parameters = tool.get("parameters") or {}
            required = set(parameters.get("required") or [])
            properties = parameters.get("properties") or {}
            for parameter_name, spec in properties.items():
                raw_type = spec.get("type")
                if isinstance(raw_type, list):
                    type_text = "/".join(str(value) for value in raw_type)
                else:
                    type_text = str(raw_type or "-")
                option_text = ""
                if spec.get("enum"):
                    option_text = " opções=" + ",".join(str(value) for value in spec.get("enum") or [])
                tool_lines.append(
                    f"  - {parameter_name}: tipo={type_text} "
                    f"required_api={'sim' if parameter_name in required else 'não'}{option_text}"
                )
            tool_lines.append("")
        tools_text = "\n".join(tool_lines).rstrip() or "(nenhuma)"
        return (
            "INSTRUCTIONS:\n" + ROUTER_INSTRUCTIONS +
            "\n\nINPUT:\n" + prompt +
            "\n\nTOOLS AUTORIZADAS ENVIADAS:\n" + tools_text
        )

    def route(self, sender: str, subject: str, body: str) -> RouteResult:
        tools = self.function_map.openai_tools_for_sender(sender)
        if not tools:
            return RouteResult(request=None, response_id="", selected_name="")

        prompt = self.build_prompt(sender, subject, body)
        response = self.client.responses.create(
            model=self.model,
            instructions=ROUTER_INSTRUCTIONS,
            input=prompt,
            tools=tools,
            tool_choice="auto",
            parallel_tool_calls=False,
            reasoning={"effort": self.reasoning_effort},
        )
        response_id = str(getattr(response, "id", "") or "")
        calls = [item for item in self._output_items(response) if getattr(item, "type", "") == "function_call"]
        if not calls:
            return RouteResult(request=None, response_id=response_id, selected_name="")
        if len(calls) != 1:
            raise RuntimeError(f"roteador retornou {len(calls)} chamadas; esperado no máximo 1")

        call = calls[0]
        name = str(getattr(call, "name", "") or "").strip()
        arguments = getattr(call, "arguments", "{}")
        if not name:
            raise RuntimeError("roteador retornou chamada sem nome de função")
        request = self.function_map.request_from_tool_call(sender, name, arguments)
        return RouteResult(request=request, response_id=response_id, selected_name=name)
