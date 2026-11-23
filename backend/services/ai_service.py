import os
import json
from typing import Optional
from google import genai
from google.genai import types

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
PRIMARY_LOCATION = "global"
PRIMARY_MODEL_ID = "gemini-4-hydrogen"
FALLBACK_LOCATION = "us-central1"
FALLBACK_MODEL_ID = "gemini-2.5-flash"

try:
    primary_client = genai.Client(
        vertexai=True,
        project=PROJECT_ID,
        location=PRIMARY_LOCATION,
        http_options=types.HttpOptions(timeout=4200),
    )
except Exception as e:
    print(f"Failed to initialize primary Gemini 4 Hydrogen client: {e}")
    primary_client = None

try:
    fallback_client = genai.Client(
        vertexai=True,
        project=PROJECT_ID,
        location=FALLBACK_LOCATION,
        http_options=types.HttpOptions(timeout=3000),
    )
except Exception as e:
    print(f"Failed to initialize fallback Gemini 2.5 Flash client: {e}")
    fallback_client = None

_MODERATION_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "is_safe": {"type": "BOOLEAN"},
        "cta_text": {"type": "STRING", "nullable": True},
        "cta_action": {
            "type": "STRING",
            "enum": ["phone", "url", "directions", "none"],
        },
    },
    "required": ["is_safe", "cta_action"],
}

_SAFETY_SETTINGS = [
    types.SafetySetting(
        category=types.HarmCategory.HARM_CATEGORY_HATE_SPEECH,
        threshold=types.HarmBlockThreshold.BLOCK_ONLY_HIGH,
    ),
    types.SafetySetting(
        category=types.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
        threshold=types.HarmBlockThreshold.BLOCK_ONLY_HIGH,
    ),
    types.SafetySetting(
        category=types.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
        threshold=types.HarmBlockThreshold.BLOCK_ONLY_HIGH,
    ),
    types.SafetySetting(
        category=types.HarmCategory.HARM_CATEGORY_HARASSMENT,
        threshold=types.HarmBlockThreshold.BLOCK_ONLY_HIGH,
    ),
]


def _parse_moderation_json(raw_text: str) -> dict:
    cleaned = (raw_text or "").strip()
    if cleaned.startswith("```json"):
        cleaned = cleaned[7:]
    elif cleaned.startswith("```"):
        cleaned = cleaned[3:]
    if cleaned.endswith("```"):
        cleaned = cleaned[:-3]
    result = json.loads(cleaned.strip())
    action = result.get("cta_action", "none")
    if action not in ("phone", "url", "directions", "none"):
        action = "none"
    return {
        "is_safe": bool(result.get("is_safe", True)),
        "cta_text": result.get("cta_text"),
        "cta_action": action,
    }


def analyze_post_content(content: str, place_name: Optional[str] = None, place_category: Optional[str] = None) -> dict:
    """
    Analyzes the post text using Gemini 4 Hydrogen (thinking_level=LOW for ~1.9s latency)
    and falls back automatically to GA Gemini 2.5 Flash (thinking_budget=0) if needed:
    1. Checks for safety flags.
    2. Generates a concise contextual Call to Action (CTA).
    Returns a dict with: is_safe (bool), cta_text (str | None), cta_action (str)
    """
    if not primary_client and not fallback_client:
        return {"is_safe": True, "cta_text": None, "cta_action": None}

    context_str = ""
    if place_name or place_category:
        context_str = (
            f"This AR post was physically pinned to a building/location: "
            f"{place_name or 'Unknown'} (Category: {place_category or 'Unknown'}). "
        )

    prompt = (
        f"Analyze this user-generated AR post. {context_str}\n"
        'Return JSON with: '
        '"is_safe" (false only if hateful, illegal, explicit, or abusive; true otherwise), '
        '"cta_text" (1-3 word button label like "Walk Here", "Get Directions", "Call Now", "View Menu", or null if none fits), '
        '"cta_action" (one of "phone", "url", "directions", "none").\n'
        f'Post content: "{content}"'
    )

    if primary_client:
        try:
            response = primary_client.models.generate_content(
                model=PRIMARY_MODEL_ID,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=_MODERATION_SCHEMA,
                    thinking_config=types.ThinkingConfig(thinking_level="LOW"),
                    safety_settings=_SAFETY_SETTINGS,
                ),
            )
            return _parse_moderation_json(response.text)
        except Exception as e:
            print(f"Primary Gemini 4 Hydrogen failed/timed out, falling back to 2.5 Flash: {e}")

    if fallback_client:
        try:
            response = fallback_client.models.generate_content(
                model=FALLBACK_MODEL_ID,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=_MODERATION_SCHEMA,
                    thinking_config=types.ThinkingConfig(thinking_budget=0),
                    safety_settings=_SAFETY_SETTINGS,
                ),
            )
            return _parse_moderation_json(response.text)
        except Exception as e:
            print(f"Fallback Gemini 2.5 Flash error: {e}")

    # Default to safe with no CTA on AI timeout/error so user post creation never stalls
    return {"is_safe": True, "cta_text": None, "cta_action": "none"}
