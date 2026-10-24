# Una imagen por nube, mismo código:
#   docker build --target aws --platform linux/arm64 -t lakehouse:aws .
#   docker build --target gcp --platform linux/amd64 -t lakehouse:gcp .
ARG PYTHON_VERSION=3.12

# --- AWS Lambda ---------------------------------------------------------------
FROM public.ecr.aws/lambda/python:${PYTHON_VERSION} AS aws

COPY pyproject.toml README.md /build/
COPY src /build/src
RUN pip install --no-cache-dir /build && rm -rf /build

# Las extensiones de DuckDB se instalan al construir: en Lambda solo /tmp es escribible
# y descargarlas en cada arranque en frío sumaría latencia.
ENV DUCKDB_EXTENSION_DIRECTORY=/opt/duckdb/extensions
RUN python -c "import duckdb; c = duckdb.connect(config={'extension_directory': '/opt/duckdb/extensions'}); [c.install_extension(e) for e in ('httpfs', 'aws')]"

COPY dbt ${LAMBDA_TASK_ROOT}/dbt
ENV DBT_PROJECT_DIR=${LAMBDA_TASK_ROOT}/dbt \
    DBT_WORK_DIR=/tmp/dbt \
    DBT_TARGET=aws \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    HOME=/tmp

CMD ["lakehouse.handlers.aws_lambda.handler"]

# --- GCP Cloud Run ------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS gcp

COPY pyproject.toml README.md /build/
COPY src /build/src
RUN pip install --no-cache-dir /build && rm -rf /build

ENV DUCKDB_EXTENSION_DIRECTORY=/opt/duckdb/extensions
RUN python -c "import duckdb; c = duckdb.connect(config={'extension_directory': '/opt/duckdb/extensions'}); c.install_extension('httpfs')"

RUN useradd --create-home --uid 1000 app
COPY dbt /app/dbt
ENV DBT_PROJECT_DIR=/app/dbt \
    DBT_WORK_DIR=/tmp/dbt \
    DBT_TARGET=gcp \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    PYTHONUNBUFFERED=1 \
    PORT=8080
USER app
WORKDIR /app

CMD ["python", "-m", "lakehouse.handlers.gcp_cloud_run"]
