# =============================================================================
# OpenEMR on EKS Console Makefile
# =============================================================================
# Note: This Makefile is designed for macOS systems only.
# For Windows, use start_console.ps1 instead, which creates a static binary
# called openemr-eks-console.exe that can be double-clicked to launch.
# =============================================================================

.PHONY: build test install uninstall clean run

BINARY_NAME=openemr-eks-console
INSTALL_PATH=/usr/local/bin
BINARY_PATH=$(INSTALL_PATH)/$(BINARY_NAME)

# Get the project root directory (parent of console directory)
# realpath gets the absolute path of the Makefile, dirname gets its parent (project root)
# The Makefile is in console/, so we need the parent directory
CONSOLE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(shell dirname $(CONSOLE_DIR))

build:
	@echo "Building console..."
	@go build -ldflags "-X main.embeddedProjectRoot=$(PROJECT_ROOT)" -o $(BINARY_NAME) main.go
	@chmod +x $(BINARY_NAME)
	@echo "Build complete: ./$(BINARY_NAME)"
	@echo "Embedded project root: $(PROJECT_ROOT)"

install: build
	@echo "Installing to $(BINARY_PATH)..."
	@echo "Embedding project root: $(PROJECT_ROOT)"
	@go build -ldflags "-X main.embeddedProjectRoot=$(PROJECT_ROOT)" -o $(BINARY_NAME) main.go
	@sudo cp $(BINARY_NAME) $(BINARY_PATH)
	@sudo chmod +x $(BINARY_PATH)
	@echo "Installed successfully!"
	@echo "Run with: $(BINARY_NAME)"
	@echo ""
	@echo "Note: Project root is embedded as: $(PROJECT_ROOT)"
	@echo "If you move the project, set OPENEMR_EKS_PROJECT_ROOT environment variable."

uninstall:
	@echo "Uninstalling $(BINARY_NAME) from $(BINARY_PATH)..."
	@if [ -f "$(BINARY_PATH)" ]; then \
		sudo rm -f $(BINARY_PATH); \
		echo "✅ Uninstalled successfully!"; \
		echo "Removed: $(BINARY_PATH)"; \
	else \
		echo "⚠️  Binary not found at $(BINARY_PATH)"; \
		echo "Nothing to uninstall."; \
	fi

test:
	@echo "Running unit tests..."
	@go test -v -race -coverprofile=coverage.out ./...
	@echo ""
	@echo "📊 Coverage summary:"
	@go tool cover -func=coverage.out | tail -1
	@rm -f coverage.out

clean:
	@echo "Cleaning..."
	@rm -f $(BINARY_NAME) coverage.out
	@echo "Clean complete"

run: build
	@./$(BINARY_NAME)
