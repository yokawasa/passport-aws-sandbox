FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY --chmod=644 requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 非 root で動かす
RUN useradd --create-home --uid 10001 appuser

# COPY はビルドコンテキストのパーミッションを引き継ぐため、
# --chown / --chmod で明示する。これが無いとローカルの umask 次第で
# uid 10001 から読めないイメージができる。
COPY --chown=10001:10001 --chmod=644 main.py .

USER 10001

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
