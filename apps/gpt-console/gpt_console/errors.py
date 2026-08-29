class GptConsoleError(Exception):
    """Erro esperado e apresentável ao usuário."""


class ConfigurationError(GptConsoleError):
    """Configuração ausente ou inválida."""


class CatalogError(GptConsoleError):
    """Catálogo de ações ausente ou inválido."""


class ApiError(GptConsoleError):
    """Falha normalizada da OpenAI API."""


class ZipWorkflowError(GptConsoleError):
    """Falha segura no fluxo de edição de ZIP."""
