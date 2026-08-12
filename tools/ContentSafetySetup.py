import os
import requests
from pathlib import Path
from dotenv import load_dotenv

# Cargar variables de entorno (environment.env está en la raíz del repo)
dotenv_path = Path(__file__).resolve().parent.parent / "environment.env"
load_dotenv(dotenv_path)

ENDPOINT = os.getenv("CONTENT_SAFETY_ENDPOINT")
KEY = os.getenv("CONTENT_SAFETY_KEY")

if not ENDPOINT or not KEY:
    raise ValueError("Faltan las variables CONTENT_SAFETY_ENDPOINT o CONTENT_SAFETY_KEY en environment.env")

# Asegurar que el endpoint no termine en barra
ENDPOINT = ENDPOINT.rstrip("/")
# Usamos una versión reciente para soportar Prompt Shields
API_VERSION = "2024-09-01"

def manage_blocklist(blocklist_name, description):
    """Crea o actualiza una lista de bloqueo (Blocklist)."""
    url = f"{ENDPOINT}/contentsafety/text/blocklists/{blocklist_name}?api-version={API_VERSION}"
    headers = {
        "Ocp-Apim-Subscription-Key": KEY,
        "Content-Type": "application/json"
    }
    body = {
        "description": description
    }
    
    response = requests.patch(url, headers=headers, json=body)
    if response.status_code in [200, 201]:
        print(f"✅ Blocklist '{blocklist_name}' creada/actualizada correctamente.")
    else:
        print(f"❌ Error al crear blocklist: {response.status_code} - {response.text}")

def add_blocklist_items(blocklist_name, items):
    """Añade palabras a la lista de bloqueo."""
    url = f"{ENDPOINT}/contentsafety/text/blocklists/{blocklist_name}/blocklistItems?api-version={API_VERSION}"
    headers = {
        "Ocp-Apim-Subscription-Key": KEY,
        "Content-Type": "application/json"
    }
    
    # La API permite añadir items en batch
    body = {
        "blocklistItems": [{"text": item, "description": "Added via script"} for item in items]
    }
    
    response = requests.post(url, headers=headers, json=body)
    if response.status_code in [200, 201]:
        print(f"✅ {len(items)} palabras añadidas a '{blocklist_name}'.")
    else:
        print(f"❌ Error al añadir items: {response.status_code} - {response.text}")

def analyze_prompt_input(text, blocklist_name=None):
    """
    Analiza la ENTRADA (Prompt) del usuario.
    Incluye: Prompt Shields (Jailbreak) + Categorías + Blocklist
    """
    print(f"\n🔍 [ENTRADA] Analizando prompt: '{text}'...")
    
    # 1. Análisis de Texto (Categorías + Blocklist)
    # Nota: Prompt Shield suele tener su propio endpoint o parámetro según la versión.
    # En la versión 2024-09-01, usamos /text:shieldPrompt para ataques específicos
    # o /text:analyze para contenido. Haremos ambas comprobaciones.
    
    # A) Comprobar Prompt Shield (Jailbreak)
    shield_url = f"{ENDPOINT}/contentsafety/text:shieldPrompt?api-version={API_VERSION}"
    headers = {
        "Ocp-Apim-Subscription-Key": KEY,
        "Content-Type": "application/json"
    }
    shield_body = {
        "userPrompt": text,
        "documents": [] # Opcional: para detectar ataques indirectos en documentos
    }
    
    shield_response = requests.post(shield_url, headers=headers, json=shield_body)
    if shield_response.status_code == 200:
        shield_result = shield_response.json()
        user_prompt_analysis = shield_result.get("userPromptAnalysis", {})
        if user_prompt_analysis.get("attackDetected"):
            print(f"🛡️ ALERTA: ¡Ataque de Jailbreak detectado! (Prompt Shield)")
            return False # Bloquear inmediatamente
        else:
            print("🛡️ Prompt Shield: OK (No se detectó ataque)")
    else:
        print(f"⚠️ No se pudo verificar Prompt Shield (Status {shield_response.status_code}). Continuando...")

    # B) Comprobar Contenido (Odio, Violencia, Blocklist)
    analyze_url = f"{ENDPOINT}/contentsafety/text:analyze?api-version={API_VERSION}"
    analyze_body = {
        "text": text,
        "categories": ["Hate", "SelfHarm", "Sexual", "Violence"],
        "outputType": "FourSeverityLevels",
        "haltOnBlocklistHit": False
    }
    if blocklist_name:
        analyze_body["blocklistNames"] = [blocklist_name]
        analyze_body["breakByBlocklists"] = True

    response = requests.post(analyze_url, headers=headers, json=analyze_body)
    if response.status_code != 200:
        print(f"❌ Error en análisis de contenido: {response.status_code} - {response.text}")
        return False

    result = response.json()
    return evaluate_result(result)

def analyze_completion_output(text, blocklist_name=None):
    """
    Analiza la SALIDA (Completion) del modelo.
    Incluye: Categorías + Blocklist (No suele requerir Prompt Shield)
    """
    print(f"\n🔍 [SALIDA] Analizando respuesta del modelo: '{text}'...")
    
    url = f"{ENDPOINT}/contentsafety/text:analyze?api-version={API_VERSION}"
    headers = {
        "Ocp-Apim-Subscription-Key": KEY,
        "Content-Type": "application/json"
    }
    
    body = {
        "text": text,
        "categories": ["Hate", "SelfHarm", "Sexual", "Violence"],
        "outputType": "FourSeverityLevels",
        "haltOnBlocklistHit": False
    }
    if blocklist_name:
        body["blocklistNames"] = [blocklist_name]
        body["breakByBlocklists"] = True

    response = requests.post(url, headers=headers, json=body)
    if response.status_code != 200:
        print(f"❌ Error en análisis de salida: {response.status_code} - {response.text}")
        return False

    result = response.json()
    return evaluate_result(result)

def evaluate_result(result):
    """Evalúa el JSON de respuesta de /text:analyze"""
    # 1. Comprobar Blocklist
    blocklist_match = result.get("blocklistsMatch")
    if blocklist_match:
        print(f"⚠️ BLOQUEADO POR LISTA PERSONALIZADA: {blocklist_match}")
        return False

    # 2. Comprobar Categorías
    thresholds = {"Hate": 0, "SelfHarm": 0, "Sexual": 0, "Violence": 0}
    categories = result.get("categoriesAnalysis", [])
    safe = True
    
    for cat in categories:
        category = cat["category"]
        severity = cat["severity"]
        limit = thresholds.get(category, 0)
        
        if severity > limit:
            print(f"🔴 RECHAZADO: {category} (Severidad {severity} > {limit})")
            safe = False
        else:
            # print(f"🟢 OK: {category} ({severity})") # Descomentar para ver detalles
            pass

    if safe:
        print("✅ Contenido SEGURO.")
        return True
    else:
        print("🚫 Contenido BLOQUEADO por categorías.")
        return False

def main():
    print("--- Configuración de Azure AI Content Safety (con Prompt Shields) ---")
    
    # 1. Configurar Blocklist
    blocklist_name = "ApimAiSecurityCustomPolicy"
    manage_blocklist(blocklist_name, "Lista de palabras prohibidas para la PoC de seguridad")
    
    # 2. Añadir palabras prohibidas
    forbidden_words = ["competencia", "secreto", "confidencial", "clave_maestra"]
    add_blocklist_items(blocklist_name, forbidden_words)
    
    # 3. Prueba interactiva
    while True:
        print("\n" + "="*30)
        mode = input("¿Probar (1) Entrada/Prompt o (2) Salida/Completion? (exit para salir): ").strip()
        
        if mode.lower() == 'exit':
            break
            
        text = input("Introduce el texto a analizar: ").strip()
        if not text:
            continue

        if mode == "1":
            is_safe = analyze_prompt_input(text, blocklist_name)
        elif mode == "2":
            is_safe = analyze_completion_output(text, blocklist_name)
        else:
            print("Opción no válida.")
            continue
            
        print(f"Resultado final: {'PASÓ' if is_safe else 'BLOQUEADO'}")

if __name__ == "__main__":
    main()
