.PHONY: help install test lint format type-check build docker-build docker-push deploy clean

help:
	@echo "Warp - Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  install       - Install Python dependencies"
	@echo "  test          - Run unit tests"
	@echo "  lint          - Run linting checks"
	@echo "  format        - Format code with black"
	@echo "  type-check    - Run type checking"
	@echo "  build         - Build Python package"
	@echo "  docker-build  - Build Docker image"
	@echo "  docker-push   - Push Docker image to registry"
	@echo "  deploy        - Deploy Kubernetes job"
	@echo "  clean         - Clean up generated files"

install:
	python3 -m pip install --user -r requirements.txt
	python3 -m pip install --user -e .

test:
	python3 -m pytest tests/ -v

lint:
	python3 -m flake8 warp/ --max-line-length=127 --extend-ignore=E203
	python3 -m black --check warp/

format:
	python3 -m black warp/

type-check:
	python3 -m mypy warp/ --ignore-missing-imports --no-strict-optional || true

build:
	python3 -m pip install --user --upgrade setuptools wheel
	python3 setup.py sdist bdist_wheel

docker-build:
	docker build -t openemr/warp:latest .

docker-push: docker-build
	docker push openemr/warp:latest

deploy:
	kubectl apply -f k8s-job.yaml

clean:
	find . -type d -name __pycache__ -exec rm -r {} +
	find . -type f -name "*.pyc" -delete
	find . -type f -name "*.pyo" -delete
	rm -rf build/ dist/ *.egg-info
	rm -f *.log
	rm -rf .pytest_cache .coverage htmlcov
