"""HTTP surface for Alice's neural voice.

  GET    /tts/status              what's installed, loaded, downloading; the reference clip; tier sizes
  POST   /tts/prepare  {tier}     load + warm a tier so the first sentence doesn't pay for it
  POST   /tts/unload              release the model now (image generation calls this first)
  POST   /tts/speak    {text,tier}  -> audio/L16 stream: little-endian int16, mono, 24 kHz
  POST   /tts/download {tier}     start fetching a tier's pinned snapshot (poll /tts/status)
  DELETE /tts/models/{tier}       remove a downloaded tier

`/tts/speak` takes text that the app has ALREADY reduced to the spoken layer. It carries no rate: Qwen
has no speed control, so the app applies the user's rate at playback (AVAudioUnitTimePitch).
"""
from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel

from .service import SAMPLE_RATE, VoiceError, voice

router = APIRouter(prefix="/tts", tags=["tts"])

_STATUS = {"not_installed": 409, "no_reference": 409, "in_use": 409, "downloading": 409, "wrong_engine": 400,
           "bad_reference": 422, "unavailable": 503}


def _error(e: Exception) -> JSONResponse:
    if isinstance(e, VoiceError):
        return JSONResponse({"code": e.code, "message": str(e)}, status_code=_STATUS.get(e.code, 500))
    if isinstance(e, ValueError):
        return JSONResponse({"code": "bad_request", "message": str(e)}, status_code=400)
    return JSONResponse({"code": "internal", "message": f"{type(e).__name__}: {e}"}, status_code=500)


class TierRequest(BaseModel):
    tier: str


class SpeakRequest(BaseModel):
    text: str
    tier: str


@router.get("/status")
async def status():
    return voice.status()


@router.post("/prepare")
async def prepare(req: TierRequest):
    try:
        return await voice.prepare(req.tier)
    except Exception as e:
        return _error(e)


@router.post("/unload")
async def unload():
    return {"unloaded": await voice.unload()}


@router.post("/speak")
async def speak(req: SpeakRequest):
    stream = voice.speak(req.text, req.tier)
    # Pull the first chunk before committing to a 200: loading happens inside the generator, and a
    # failure there must reach the app as an error it can show, not as an empty audio stream.
    try:
        first = await anext(stream)
    except StopAsyncIteration:
        return Response(status_code=204)          # nothing speakable
    except Exception as e:
        await stream.aclose()
        return _error(e)

    async def body():
        yield first
        async for chunk in stream:
            yield chunk

    return StreamingResponse(body(), media_type=f"audio/L16; rate={SAMPLE_RATE}; channels=1",
                             headers={"X-Sample-Rate": str(SAMPLE_RATE), "Cache-Control": "no-store"})


@router.post("/download")
async def download(req: TierRequest):
    try:
        return voice.start_download(req.tier)
    except Exception as e:
        return _error(e)


@router.delete("/models/{tier}")
async def delete(tier: str):
    try:
        return {"deleted": voice.delete(tier)}
    except Exception as e:
        return _error(e)
