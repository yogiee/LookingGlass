"""HTTP routes for the image model (Settings → System → Images).

  GET    /imagegen/status                     what's available, installed, downloading
  POST   /imagegen/download {model}           start (or resume) downloading a model's pinned snapshot
  POST   /imagegen/download/cancel {model}    stop it; partial files are kept for resume
  DELETE /imagegen/models/{model}             remove a model, and Core AI's specialized copy of it

Generation itself is not a route: it's Alice's `generate_image` tool (Invariant #2).
"""
from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .service import ImageGenError, service

router = APIRouter(prefix="/imagegen")


class ModelRequest(BaseModel):
    model: str


def _error(e: Exception) -> JSONResponse:
    if isinstance(e, ImageGenError):
        return JSONResponse({"code": "imagegen", "message": str(e)}, status_code=409)
    if isinstance(e, ValueError):
        return JSONResponse({"code": "bad_request", "message": str(e)}, status_code=400)
    return JSONResponse({"code": "internal", "message": f"{type(e).__name__}: {e}"}, status_code=500)


@router.get("/status")
async def status():
    return service.status()


@router.post("/download")
async def download(req: ModelRequest):
    try:
        return service.start_download(req.model)
    except Exception as e:
        return _error(e)


@router.post("/download/cancel")
async def cancel_download(req: ModelRequest):
    try:
        return service.cancel_download(req.model)
    except Exception as e:
        return _error(e)


@router.delete("/models/{model}")
async def delete(model: str):
    try:
        return {"deleted": service.delete(model)}
    except Exception as e:
        return _error(e)
