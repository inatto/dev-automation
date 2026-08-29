# GPT Console

Playground TUI da OpenAI API no padrão visual do LRDP/Dev Manager. O app separa
catálogos de ações, transcrição, cliente da API e processamento de ZIP para que
o núcleo possa ser migrado depois para os projetos Orbital.

## Instalação

O instalador global do Dev Automation cria o comando `gpt-console`. As
dependências Python da API e do microfone são instaladas uma vez:

```bash
bash apps/gpt-console/install.sh
gpt-console
```

Sem o ambiente virtual, a TUI e o diagnóstico ainda abrem com o `python3` do
sistema; chamadas da API informam exatamente qual dependência falta.

## Configuração

Pressione `F2`. A configuração é gravada em:

```text
dev-automation/.config/gpt-console/settings.env
```

Campos principais:

- `OPENAI_API_KEY`: chave normal para Responses, transcrição e arquivos;
- `OPENAI_ADMIN_KEY`: opcional, somente para consultar custos da organização;
- modelos separados para ações, áudio e ZIP;
- pastas `Code` e `Downloads`, timeout e memória do Code Interpreter.

As chaves nunca aparecem no diagnóstico ou em JSON de saída. O mecanismo já
existente do Dev Manager mascara `.config` nos ZIPs de backup e preserva os
segredos locais na importação.

## Ações

`F3` cria projetos e ações. Cada projeto vira um JSON em
`.config/gpt-console/actions/<project>.json`. A TUI converte cada ação em uma
função strict da Responses API. Um teste retorna:

```json
{
  "matched": true,
  "action": "find_member",
  "parameters": {"query": "Pedro"},
  "message": ""
}
```

O retorno só descreve a ação; o playground nunca executa alterações no Orbital.

## Voz

`F5` aceita um arquivo de áudio ou grava o microfone. O áudio é enviado para o
endpoint de transcrição e o texto volta pelo mesmo roteador de ações. A gravação
temporária é apagada ao terminar.

## ZIP

`F6` usa o `zip_name` do projeto em `/home/daniel/Code`, exige confirmação,
envia o pacote para Code Interpreter, baixa o ZIP citado na resposta, valida CRC
e caminhos internos e salva um nome único reconhecido pelo Dev Manager em
`/home/daniel/Downloads`. O GPT Console não aplica o retorno diretamente.

## CLI e testes

```bash
gpt-console --doctor
gpt-console --validate
gpt-console --dump-json
gpt-console --group orbital-app --classify 'procure o Pedro'
gpt-console --group orbital-app --transcribe /tmp/comando.wav
gpt-console --group orbital-app --zip-request 'revise o cadastro de membros'
python3 -m unittest discover -s apps/gpt-console/tests -v
```
