import os
import socket

from fastapi import FastAPI
from pydantic import BaseModel

APP_VERSION = os.getenv("APP_VERSION", "0.1.0")

app = FastAPI(
    title="Sample API on EKS",
    description="private subnet の EKS で動き、public subnet の ALB 経由で公開される API",
    version=APP_VERSION,
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


@app.post("/echo", response_model=Echo, tags=["api"])
def echo(payload: Echo) -> Echo:
    return payload
