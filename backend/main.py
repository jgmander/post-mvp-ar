from fastapi import FastAPI
import uvicorn

app = FastAPI(title="Post AR MVP Backend")

@app.get("/")
def read_root():
    return {"status": "ok", "service": "post-mvp-backend"}

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)
