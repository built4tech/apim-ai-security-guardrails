import json
import os
import unicodedata
from pathlib import Path

import requests
from dotenv import load_dotenv

# ─── Colores ANSI para la consola ───
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
WHITE = "\033[97m"
BG_RED = "\033[41m"
GRAY = "\033[90m"

# Mapa de categorías de Content Safety a español
CATEGORY_LABELS = {
    "Hate": "Odio y discriminación",
    "SelfHarm": "Autolesión",
    "Sexual": "Contenido sexual",
    "Violence": "Violencia",
}

SEVERITY_LABELS = {0: "Seguro", 2: "Bajo", 4: "Medio", 6: "Alto"}


def _visible_width(text: str) -> int:
    """Calcula el ancho visible en la terminal, teniendo en cuenta caracteres anchos y emojis."""
    width = 0
    for ch in text:
        cat = unicodedata.category(ch)
        if cat in ("Mn", "Me", "Cf"):  # marcas combinantes y formato (ancho 0)
            continue
        eaw = unicodedata.east_asian_width(ch)
        if eaw in ("W", "F"):
            width += 2
        else:
            width += 1
    return width


def _pad(text: str, target_width: int) -> str:
    """Rellena con espacios hasta alcanzar el ancho visible deseado."""
    visible = _visible_width(text)
    return text + " " * max(0, target_width - visible)


def display_security_block(error_body: dict) -> None:
    """Muestra un bloque visual profesional cuando se detecta una infracción de seguridad."""
    blocked_by = error_body.get("blocked_by", "Azure Security")
    error_msg = error_body.get("error", "Contenido bloqueado.")
    details = error_body.get("details", "")
    categories = error_body.get("flagged_categories", [])

    W = 62  # ancho interior del cuadro
    B = f"{RED}{BOLD}"  # estilo de borde
    R = RESET

    def border_line(left, fill, right):
        print(f"{B}  {left}{fill * W}{right}{R}")

    def content_line(text_with_ansi, visible_text):
        pad = " " * max(0, W - len(visible_text))
        print(f"{B}  ║{R}{text_with_ansi}{pad}{B}║{R}")

    def empty_line():
        print(f"{B}  ║{' ' * W}║{R}")

    print()
    border_line("╔", "═", "╗")
    # Título con fondo rojo
    title = "  CONTENIDO BLOQUEADO"
    title_pad = " " * max(0, W - len(title))
    print(f"{B}  ║{BG_RED}{WHITE}{BOLD}{title}{title_pad}{R}{B}║{R}")
    border_line("╠", "═", "╣")
    empty_line()

    # Componente
    comp_visible = f"  Componente: {blocked_by}"
    comp_ansi = f"  Componente: {CYAN}{BOLD}{blocked_by}{R}"
    content_line(comp_ansi, comp_visible)
    empty_line()

    # Categorías (Content Safety)
    if categories:
        hdr = "  Categorias detectadas:"
        content_line(f"{YELLOW}{hdr}{R}", hdr)

        for cat in categories:
            name = cat.get("category", "?")
            sev = cat.get("severity", 0)
            label = CATEGORY_LABELS.get(name, name)
            sev_label = SEVERITY_LABELS.get(sev, str(sev))
            filled = sev // 2
            bar = "█" * filled + "░" * (3 - filled)
            vis = f"    ► {label}  ·  Severidad: {sev_label} {bar}"
            ansi = f"  {YELLOW}  ► {label}{R}  {DIM}·{R}  Severidad: {RED}{BOLD}{sev_label}{R} {RED}{bar}{R}"
            content_line(ansi, vis)

        empty_line()

    # Detalle de Prompt Shield (sin categorías)
    if details and not categories:
        det_vis = f"  {details}"
        det_ansi = f"{YELLOW}  {details}{R}"
        content_line(det_ansi, det_vis)
        empty_line()

    # Mensaje de error (word-wrap)
    max_text_w = W - 4  # margen interno de 2 a cada lado
    words = error_msg.split()
    lines = []
    current = ""
    for word in words:
        test = f"{current} {word}" if current else word
        if len(test) > max_text_w:
            if current:
                lines.append(current)
            current = word
        else:
            current = test
    if current:
        lines.append(current)

    for line in lines:
        vis = f"  {line}"
        ansi = f"{WHITE}  {line}{R}"
        content_line(ansi, vis)

    empty_line()
    border_line("╚", "═", "╝")
    print()

# 1. Cargar entorno
# Usamos parent.parent (raíz del repo) para asegurar que encuentra el .env aunque ejecutes el script desde otra carpeta
dotenv_path = Path(__file__).resolve().parent.parent / "environment.env"
load_dotenv(dotenv_path)


# 2.- Preguntar al usuario por el tipo de conexión que quiere realizar
while True:
    print("\nSelecciona el tipo de conexión:")
    print("1. Conexión directa al proveedor (Groq) — sin capa de seguridad")
    print("2. Conexión vía APIM sin Content Safety")
    print("3. Conexión vía APIM con Content Safety")
    print("4. Conexión vía APIM con Prompt Shield")
    print("5. Conexión vía APIM con Content Safety & Prompt Shield")
    
    connection_type = input("Elige 1, 2, 3, 4 o 5: ").strip()
    
    if connection_type in ["1", "2", "3", "4", "5"]:
        break
    print("Por favor, selecciona una opción válida (1-5).")


# 3. Obtener configuración de entorno según la elección y construir la petición HTTP

# Configuración de los tipos de conexión.
#   auth="bearer" → llamada directa al proveedor (Authorization: Bearer GROQ_API_KEY)
#   auth="apim"   → llamada vía APIM (Ocp-Apim-Subscription-Key: AZURE_APIM_KEY)
CONNECTION_CONFIG = {
    "1": {
        "endpoint_var": "GROQ_ENDPOINT",
        "msg": "Conectando directamente al proveedor (Groq, sin capa de seguridad)",
        "auth": "bearer",
    },
    "2": {
        "endpoint_var": "AZURE_APIM_ENDPOINT",
        "msg": "Conectando a través de APIM (sin seguridad de contenido)",
        "auth": "apim",
    },
    "3": {
        "endpoint_var": "AZURE_APIM_ENDPOINT_CS",
        "msg": "Conectando a través de APIM (Content Safety habilitado)",
        "auth": "apim",
    },
    "4": {
        "endpoint_var": "AZURE_APIM_ENDPOINT_PS",
        "msg": "Conectando a través de APIM (Prompt Shield habilitado)",
        "auth": "apim",
    },
    "5": {
        "endpoint_var": "AZURE_APIM_ENDPOINT_CS_PS",
        "msg": "Conectando a través de APIM (Content Safety & Prompt Shield habilitados)",
        "auth": "apim",
    }
}

config = CONNECTION_CONFIG[connection_type]
selected_endpoint = os.getenv(config["endpoint_var"])
msg = config["msg"]

# Validar variables de entorno y construir las cabeceras de la petición
missing_vars = []
if not selected_endpoint:
    missing_vars.append(config["endpoint_var"])

request_headers = {"Content-Type": "application/json"}
if config["auth"] == "bearer":
    groq_key = os.getenv("GROQ_API_KEY")
    if not groq_key:
        missing_vars.append("GROQ_API_KEY")
    else:
        request_headers["Authorization"] = f"Bearer {groq_key}"
else:  # apim
    apim_key = os.getenv("AZURE_APIM_KEY")
    if not apim_key:
        missing_vars.append("AZURE_APIM_KEY")
    else:
        request_headers["Ocp-Apim-Subscription-Key"] = apim_key

if missing_vars:
    raise ValueError(
        f"Faltan las siguientes variables de entorno en {dotenv_path}: {', '.join(missing_vars)}"
    )

print(f"\n{msg}")
print(f"Endpoint: {selected_endpoint}\n")


# Modelo del proveedor. Groq usa identificadores tipo "<familia>-<tamaño>-<variante>".
# Lista los modelos activos con:
#   curl https://api.groq.com/openai/v1/models -H "Authorization: Bearer $GROQ_API_KEY"
MODEL_NAME = "llama-3.3-70b-versatile"


class SecurityBlockError(Exception):
    """Excepción personalizada para bloqueos de seguridad (Content Safety / Prompt Shield)."""
    def __init__(self, error_body: dict):
        self.error_body = error_body
        super().__init__(error_body.get("error", "Contenido bloqueado"))


def complete(user_query: str) -> str:
    """Envía la consulta al endpoint seleccionado (directo o vía APIM) por HTTP."""
    response = requests.post(
        selected_endpoint,
        headers=request_headers,
        json={
            "model": MODEL_NAME,
            "messages": [{"role": "user", "content": user_query}],
            "max_tokens": 2048,
        },
        timeout=60,
    )

    # Los bloqueos de seguridad (400 con cuerpo estructurado) solo los emite APIM.
    # En conexión directa un 400 es un error normal de la API del proveedor.
    if response.status_code == 400 and config["auth"] == "apim":
        try:
            error_body = response.json()
        except (ValueError, KeyError):
            error_body = {"blocked_by": "Azure Security", "error": response.text}
        raise SecurityBlockError(error_body)

    response.raise_for_status()

    response_json = response.json()
    return response_json["choices"][0]["message"]["content"]

def prompt_chat() -> None:
    print("Escribe 'exit' para terminar la conversación")
    while True:
        try:
            user_query = input("Consulta > ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nSaliendo...")
            break

        if not user_query:
            continue
        if user_query.lower() == "exit":
            print("Saliendo...")
            break

        try:
            response_text = complete(user_query)

            print(f"\n{CYAN}Respuesta:{RESET}\n{response_text}\n")
        except SecurityBlockError as sbe:
            display_security_block(sbe.error_body)
        except Exception as exc:
            print(f"Ocurrió un error al consultar el modelo: {exc}")
            if hasattr(exc, "response") and exc.response is not None:
                try:
                    error_body = exc.response.json()
                    print(f"Detalles del error: {error_body}")
                except:
                    print(f"Cuerpo de respuesta (texto): {exc.response.text}")
            print("\n")

if __name__ == "__main__":
    prompt_chat()