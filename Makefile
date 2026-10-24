PYTHON  ?= python3
VENV    ?= .venv
BIN     := $(VENV)/bin
DOCKER  ?= docker

# Rango de días para generate/run (por defecto, la última semana).
START   ?= $(shell date -u -d '6 days ago' +%F 2>/dev/null || date -u -v-6d +%F)
END     ?= $(shell date -u +%F)

# Plataformas: deben coincidir con lambda_architecture (Terraform) y con Cloud Run (solo amd64).
AWS_PLATFORM ?= linux/arm64
GCP_PLATFORM ?= linux/amd64
TAG          ?= latest

.PHONY: install generate run lint format test test-unit docs clean \
        image-aws image-gcp aws-bootstrap aws-push aws-deploy gcp-bootstrap gcp-push gcp-deploy

install:
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install -e '.[dev]'

generate:  ## datos raw sintéticos en el lago (LAKE_ROOT o ./data/lake)
	$(BIN)/lakehouse generate --start $(START) --end $(END)

run:  ## dbt build día por día, como lo haría el evento en la nube
	$(BIN)/lakehouse run --start $(START) --end $(END)

lint:
	$(BIN)/ruff check src tests
	$(BIN)/ruff format --check src tests

format:
	$(BIN)/ruff format src tests
	$(BIN)/ruff check --fix src tests

test:
	$(BIN)/pytest

test-unit:
	$(BIN)/pytest -m "not e2e"

docs:  ## documentación y linaje de dbt en http://localhost:8080
	cd dbt && LAKE_ROOT=$(abspath data/lake) ../$(BIN)/dbt docs generate --profiles-dir . && ../$(BIN)/dbt docs serve --profiles-dir .

clean:
	rm -rf data dbt/target dbt/logs .pytest_cache .ruff_cache

image-aws:
	$(DOCKER) build --target aws --platform $(AWS_PLATFORM) -t lakehouse:aws .

image-gcp:
	$(DOCKER) build --target gcp --platform $(GCP_PLATFORM) -t lakehouse:gcp .

# --- AWS (requiere AWS CLI con credenciales) ----------------------------------
AWS_REGION ?= us-east-1
ECR_URL     = $(shell terraform -chdir=infra/aws output -raw ecr_repository_url)

aws-bootstrap:  ## crea solo el repositorio ECR: la Lambda necesita una imagen para existir
	terraform -chdir=infra/aws init
	terraform -chdir=infra/aws apply -target=aws_ecr_repository.lakehouse

aws-push: image-aws
	aws ecr get-login-password --region $(AWS_REGION) | $(DOCKER) login --username AWS --password-stdin $(firstword $(subst /, ,$(ECR_URL)))
	$(DOCKER) tag lakehouse:aws $(ECR_URL):$(TAG)
	$(DOCKER) push $(ECR_URL):$(TAG)

aws-deploy: aws-push
	terraform -chdir=infra/aws apply -var image_tag=$(TAG)

# --- GCP (requiere gcloud autenticado) ----------------------------------------
GCP_REPO    = $(shell terraform -chdir=infra/gcp output -raw image_repository)

gcp-bootstrap:  ## crea APIs y Artifact Registry antes de publicar la primera imagen
	terraform -chdir=infra/gcp init
	terraform -chdir=infra/gcp apply -target=google_artifact_registry_repository.images

gcp-push: image-gcp
	gcloud auth configure-docker $(firstword $(subst /, ,$(GCP_REPO))) --quiet
	$(DOCKER) tag lakehouse:gcp $(GCP_REPO):$(TAG)
	$(DOCKER) push $(GCP_REPO):$(TAG)

gcp-deploy: gcp-push
	terraform -chdir=infra/gcp apply -var image_tag=$(TAG)
