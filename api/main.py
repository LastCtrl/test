from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI(title="Health Check API")


@app.get("/health")
def health_check():
    return JSONResponse(content={"status": "ok"})
