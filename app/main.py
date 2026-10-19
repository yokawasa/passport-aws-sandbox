import os
import socket

from fastapi import Depends, FastAPI, HTTPException, Security, status
from fastapi.security import APIKeyHeader
from pydantic import BaseModel

APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
API_KEY = os.getenv("API_KEY", "")

app = FastAPI(
    title="Sample API on EKS",
    description="private subnet の EKS で動き、public subnet の ALB 経由で公開される API",
    version=APP_VERSION,
)

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def require_api_key(api_key: str = Security(api_key_header)) -> None:
    if not API_KEY or api_key != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
        )


class Health(BaseModel):
    status: str


class Info(BaseModel):
    message: str
    version: str
    hostname: str


class Echo(BaseModel):
    message: str


@app.get("/healthz", response_model=Health, tags=["system"])
def healthz() -> Health:
    """ALB ターゲットグループのヘルスチェック用。"""
    return Health(status="ok")


@app.get("/", response_model=Info, tags=["api"])
def root() -> Info:
    return Info(
        message="Hello from EKS",
        version=APP_VERSION,
        hostname=socket.gethostname(),
    )


@app.post(
    "/echo",
    response_model=Echo,
    tags=["api"],
    dependencies=[Depends(require_api_key)],
)
def echo(payload: Echo) -> Echo:
    return payload
