FROM python:3.14-slim

WORKDIR /app

# Install system dependencies (minimal) with security best practices
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY warp/ ./warp/
COPY setup.py .
COPY README.md .

# Install warp as a package
RUN pip install --no-cache-dir -e .

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash warp && \
    chown -R warp:warp /app
USER warp

# Set Python path
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

# Default command
CMD ["warp", "--help"]
