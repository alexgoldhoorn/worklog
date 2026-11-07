FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
COPY worklog ./worklog
COPY balance ./balance
COPY day ./day
RUN uv sync --frozen --no-dev
ENV HOME=/tmp
EXPOSE 8000
USER 1000:1000
CMD [".venv/bin/uvicorn", "worklog.web.app:factory", "--factory", "--host", "0.0.0.0", "--port", "8000"]
