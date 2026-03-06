import os
from google.cloud import aiplatform
from vertexai.generative_models import GenerativeModel, HarmCategory, HarmBlockThreshold
import json

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
LOCATION = "us-central1"

try:
    aiplatform.init(project=PROJECT_ID, location=LOCATION)
    # Using gemini-1.5-flash for speed and cost efficiency
    model = GenerativeModel("gemini-1.5-flash-001")
except Exception as e:
    print(f"Failed to initialize AI Platform: {e}")
    model = None

def analyze_post_content(content: str) -> dict:
    """
    Analyzes the post text to:
    1. Check for safety flags.
    2. Generate a relevant Call to Action (CTA).
    Returns a dict with: is_safe (bool), cta_text (str), cta_action (str)
    """
    if not model:
        return {"is_safe": True, "cta_text": None, "cta_action": None}
    
    prompt = f"""
    Analyze the following user-generated AR post content.
    Provide a JSON response with three keys:
    1. "is_safe": boolean. False if the content is highly offensive, illegal, or violates typical community standards. True otherwise.
    2. "cta_text": string. A 1 to 3 word suggested button text (e.g., "Call Now", "Get Directions", "Buy Tickets"). If no CTA makes sense, return null.
    3. "cta_action": string. The type of action: "phone", "url", "directions", "none". If no CTA, return "none".
    
    Post content: "{content}"
    
    Return ONLY valid JSON.
    """
    
    safety_settings = {
        HarmCategory.HARM_CATEGORY_HATE_SPEECH: HarmBlockThreshold.BLOCK_ONLY_HIGH,
        HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT: HarmBlockThreshold.BLOCK_ONLY_HIGH,
        HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT: HarmBlockThreshold.BLOCK_ONLY_HIGH,
        HarmCategory.HARM_CATEGORY_HARASSMENT: HarmBlockThreshold.BLOCK_ONLY_HIGH,
    }
    
    try:
        response = model.generate_content(
            prompt,
            safety_settings=safety_settings
        )
        # Parse JSON from response
        # Sometimes model wraps in ```json ... ```
        raw_text = response.text.strip()
        if raw_text.startswith("```json"):
            raw_text = raw_text[7:]
        if raw_text.endswith("```"):
            raw_text = raw_text[:-3]
            
        result = json.loads(raw_text.strip())
        return {
            "is_safe": result.get("is_safe", True),
            "cta_text": result.get("cta_text"),
            "cta_action": result.get("cta_action")
        }
    except Exception as e:
        print(f"Error calling Gemini: {e}")
        # Default to safe with no CTA on failure
        return {"is_safe": True, "cta_text": None, "cta_action": None}
