FROM python:3.12-slim AS deps
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.12-slim AS runtime
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH=/home/appuser/.local/bin:$PATH

RUN useradd --create-home appuser
COPY --from=deps /root/.local /home/appuser/.local
COPY app.py .
RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 3000
# gunicorn, not `flask run` - flask's own dev server is single-threaded and
# explicitly not meant for production; gunicorn is the standard WSGI server
# used to actually serve Python web apps.
CMD ["gunicorn", "--bind", "0.0.0.0:3000", "app:app"]
