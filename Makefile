include ./Makefile.Common

# This is the code that we want to run lint, etc.
ALL_SRC := $(shell find . -name '*.go' \
							-not -path './internal/tools/*' \
							-not -path '*/third_party/*' \
							-not -path './pdata/internal/data/protogen/*' \
							-not -path './service/internal/zpages/tmplgen/*' \
							-type f | sort)

# All source code and documents. Used in spell check.
ALL_DOC := $(shell find . \( -name "*.md" -o -name "*.yaml" \) \
                                -type f | sort)

# ALL_MODULES includes ./* dirs (excludes . dir)
ALL_MODULES := $(shell find . -type f -name "go.mod" -exec dirname {} \; | sort | grep -E '^./' )

CMD?=

RUN_CONFIG?=examples/local/otel-config.yaml
CONTRIB_PATH=$(CURDIR)/../opentelemetry-collector-contrib
COMP_REL_PATH=cmd/otelcorecol/components.go
MOD_NAME=go.opentelemetry.io/collector

# Function to execute a command. Note the empty line before endef to make sure each command
# gets executed separately instead of concatenated with previous one.
# Accepts command to execute as first parameter.
define exec-command
$(1)

endef

.DEFAULT_GOAL := all

.PHONY: all
all: checklicense checkdoc misspell goimpi goporto multimod-verify golint gotest

all-modules:
	@echo $(ALL_MODULES) | tr ' ' '\n' | sort

.PHONY: gomoddownload
gomoddownload:
	@$(MAKE) for-all-target TARGET="moddownload"

.PHONY: gotest
gotest:
	@$(MAKE) for-all-target TARGET="test"

.PHONY: gobenchmark
gobenchmark:
	@$(MAKE) for-all-target TARGET="benchmark"
	cat `find . -name benchmark.txt` > benchmarks.txt

.PHONY: gotest-with-cover
gotest-with-cover:
	@$(MAKE) for-all-target TARGET="test-with-cover"
	$(GOCMD) tool covdata textfmt -i=./coverage/unit -o ./coverage.txt

.PHONY: gotest-with-junit
gotest-with-junit:
	@$(MAKE) for-all-target TARGET="test-with-junit"

.PHONY: gotestifylint-fix
gotestifylint-fix:
	$(MAKE) for-all-target TARGET="testifylint-fix"

.PHONY: goporto
goporto: $(PORTO)
	$(PORTO) -w --include-internal --skip-dirs "^cmd/mdatagen/third_party$$" ./

.PHONY: for-all
for-all:
	@echo "running $${CMD} in root"
	@$${CMD}
	@set -e; for dir in $(GOMODULES); do \
	  (cd "$${dir}" && \
	  	echo "running $${CMD} in $${dir}" && \
	 	$${CMD} ); \
	done

.PHONY: golint
golint:
	@$(MAKE) for-all-target TARGET="lint"

.PHONY: goimpi
goimpi:
	@$(MAKE) for-all-target TARGET="impi"

.PHONY: gofmt
gofmt:
	@$(MAKE) for-all-target TARGET="fmt"

.PHONY: gotidy
gotidy:
	@$(MAKE) for-all-target TARGET="tidy"

.PHONY: gogenerate
gogenerate:
	cd cmd/mdatagen && $(GOCMD) install .
	@$(MAKE) for-all-target TARGET="generate"
	$(MAKE) fmt

.PHONY: addlicense
addlicense: $(ADDLICENSE)
	@ADDLICENSEOUT=`$(ADDLICENSE) -s=only -y "" -c "The OpenTelemetry Authors" $(ALL_SRC) 2>&1`; \
		if [ "$$ADDLICENSEOUT" ]; then \
			echo "$(ADDLICENSE) FAILED => add License errors:\n"; \
			echo "$$ADDLICENSEOUT\n"; \
			exit 1; \
		else \
			echo "Add License finished successfully"; \
		fi

.PHONY: checklicense
checklicense: $(ADDLICENSE)
	@licRes=$$(for f in $$(find . -type f \( -iname '*.go' -o -iname '*.sh' \) ! -path '**/third_party/*') ; do \
	           awk '/Copyright The OpenTelemetry Authors|generated|GENERATED/ && NR<=3 { found=1; next } END { if (!found) print FILENAME }' $$f; \
			   awk '/SPDX-License-Identifier: Apache-2.0|generated|GENERATED/ && NR<=4 { found=1; next } END { if (!found) print FILENAME }' $$f; \
	   done); \
	   if [ -n "$${licRes}" ]; then \
	           echo "license header checking failed:"; echo "$${licRes}"; \
	           exit 1; \
	   fi

.PHONY: misspell
misspell: $(MISSPELL)
	$(MISSPELL) -error $(ALL_DOC)

.PHONY: misspell-correction
misspell-correction: $(MISSPELL)
	$(MISSPELL) -w $(ALL_DOC)

.PHONY: run
run: otelcorecol
	./bin/otelcorecol_$(GOOS)_$(GOARCH) --config ${RUN_CONFIG} ${RUN_ARGS}

# Append root module to all modules
GOMODULES = $(ALL_MODULES) $(PWD)

# Define a delegation target for each module
.PHONY: $(GOMODULES)
$(GOMODULES):
	@echo "Running target '$(TARGET)' in module '$@'"
	$(MAKE) -C $@ $(TARGET)

# Triggers each module's delegation target
.PHONY: for-all-target
for-all-target: $(GOMODULES)

.PHONY: check-component
check-component:
ifndef COMPONENT
	$(error COMPONENT variable was not defined)
endif

# Build the Collector executable.
.PHONY: otelcorecol
otelcorecol:
	pushd cmd/otelcorecol && CGO_ENABLED=0 $(GOCMD) build -trimpath -o ../../bin/otelcorecol_$(GOOS)_$(GOARCH) \
		-tags $(GO_BUILD_TAGS) ./cmd/otelcorecol && popd

.PHONY: genotelcorecol
genotelcorecol: install-tools
	pushd cmd/builder/ && $(GOCMD) run ./ --skip-compilation --config ../otelcorecol/builder-config.yaml --output-path ../otelcorecol && popd
	$(MAKE) -C cmd/otelcorecol fmt

.PHONY: ocb
ocb:
	$(MAKE) -C cmd/builder config
	$(MAKE) -C cmd/builder ocb

# Definitions for ProtoBuf generation.

# The source directory for OTLP ProtoBufs.
OPENTELEMETRY_PROTO_SRC_DIR=pdata/internal/opentelemetry-proto

# The branch matching the current version of the proto to use
OPENTELEMETRY_PROTO_VERSION=v1.5.0

# Find all .proto files.
OPENTELEMETRY_PROTO_FILES := $(subst $(OPENTELEMETRY_PROTO_SRC_DIR)/,,$(wildcard $(OPENTELEMETRY_PROTO_SRC_DIR)/opentelemetry/proto/*/v1/*.proto $(OPENTELEMETRY_PROTO_SRC_DIR)/opentelemetry/proto/collector/*/v1/*.proto $(OPENTELEMETRY_PROTO_SRC_DIR)/opentelemetry/proto/*/v1development/*.proto $(OPENTELEMETRY_PROTO_SRC_DIR)/opentelemetry/proto/collector/*/v1development/*.proto))

# Target directory to write generated files to.
PROTO_TARGET_GEN_DIR=pdata/internal/data/protogen

# Go package name to use for generated files.
PROTO_PACKAGE=go.opentelemetry.io/collector/$(PROTO_TARGET_GEN_DIR)

# Intermediate directory used during generation.
PROTO_INTERMEDIATE_DIR=pdata/internal/.patched-otlp-proto

DOCKERCMD ?= docker
DOCKER_PROTOBUF ?= otel/build-protobuf:0.23.0
PROTOC := $(DOCKERCMD) run --rm -u ${shell id -u} -v${PWD}:${PWD} -w${PWD}/$(PROTO_INTERMEDIATE_DIR) ${DOCKER_PROTOBUF} --proto_path=${PWD}
PROTO_INCLUDES := -I/usr/include/github.com/gogo/protobuf -I./

# Cleanup temporary directory
genproto-cleanup:
	rm -Rf ${OPENTELEMETRY_PROTO_SRC_DIR}

# Generate OTLP Protobuf Go files. This will place generated files in PROTO_TARGET_GEN_DIR.
genproto: genproto-cleanup
	mkdir -p ${OPENTELEMETRY_PROTO_SRC_DIR}
	curl -sSL https://api.github.com/repos/open-telemetry/opentelemetry-proto/tarball/${OPENTELEMETRY_PROTO_VERSION} | tar xz --strip 1 -C ${OPENTELEMETRY_PROTO_SRC_DIR}
	# Call a sub-make to ensure OPENTELEMETRY_PROTO_FILES is populated
	$(MAKE) genproto_sub
	$(MAKE) fmt
	$(MAKE) genproto-cleanup

genproto_sub:
	@echo Generating code for the following files:
	@$(foreach file,$(OPENTELEMETRY_PROTO_FILES),$(call exec-command,echo $(file)))

	@echo Delete intermediate directory.
	@rm -rf $(PROTO_INTERMEDIATE_DIR)

	@echo Copy .proto file to intermediate directory.
	mkdir -p $(PROTO_INTERMEDIATE_DIR)/opentelemetry
	cp -R $(OPENTELEMETRY_PROTO_SRC_DIR)/opentelemetry/* $(PROTO_INTERMEDIATE_DIR)/opentelemetry

	# Patch proto files. See proto_patch.sed for patching rules.
	@echo Modify them in the intermediate directory.
	$(foreach file,$(OPENTELEMETRY_PROTO_FILES),$(call exec-command,sed -f proto_patch.sed $(OPENTELEMETRY_PROTO_SRC_DIR)/$(file) > $(PROTO_INTERMEDIATE_DIR)/$(file)))

	# HACK: Workaround for istio 1.15 / envoy 1.23.1 mistakenly emitting deprecated field.
	# reserved 1000 -> repeated ScopeLogs deprecated_scope_logs = 1000;
	sed 's/reserved 1000;/repeated ScopeLogs deprecated_scope_logs = 1000;/g' $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/logs/v1/logs.proto 1<> $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/logs/v1/logs.proto
	# reserved 1000 -> repeated ScopeMetrics deprecated_scope_metrics = 1000;
	sed 's/reserved 1000;/repeated ScopeMetrics deprecated_scope_metrics = 1000;/g' $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/metrics/v1/metrics.proto 1<> $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/metrics/v1/metrics.proto
	# reserved 1000 -> repeated ScopeSpans deprecated_scope_spans = 1000;
	sed 's/reserved 1000;/repeated ScopeSpans deprecated_scope_spans = 1000;/g' $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/trace/v1/trace.proto 1<> $(PROTO_INTERMEDIATE_DIR)/opentelemetry/proto/trace/v1/trace.proto


	@echo Generate Go code from .proto files in intermediate directory.
	$(foreach file,$(OPENTELEMETRY_PROTO_FILES),$(call exec-command,$(PROTOC) $(PROTO_INCLUDES) --gogofaster_out=plugins=grpc:./ $(file)))

	@echo Move generated code to target directory.
	mkdir -p $(PROTO_TARGET_GEN_DIR)
	cp -R $(PROTO_INTERMEDIATE_DIR)/$(PROTO_PACKAGE)/* $(PROTO_TARGET_GEN_DIR)/
	rm -rf $(PROTO_INTERMEDIATE_DIR)/go.opentelemetry.io

	@rm -rf $(OPENTELEMETRY_PROTO_SRC_DIR)/*
	@rm -rf $(OPENTELEMETRY_PROTO_SRC_DIR)/.* > /dev/null 2>&1 || true

# Generate structs, functions and tests for pdata package. Must be used after any changes
# to proto and after running `make genproto`
genpdata:
	pushd pdata/ && $(GOCMD) run ./internal/cmd/pdatagen/main.go && popd
	$(MAKE) fmt

# Generate semantic convention constants. Requires a clone of the opentelemetry-specification repo
gensemconv: $(SEMCONVGEN) $(SEMCONVKIT)
	@[ "${SPECPATH}" ] || ( echo ">> env var SPECPATH is not set"; exit 1 )
	@[ "${SPECTAG}" ] || ( echo ">> env var SPECTAG is not set"; exit 1 )
	@echo "Generating semantic convention constants from specification version ${SPECTAG} at ${SPECPATH}"
	$(SEMCONVGEN) -o semconv/${SPECTAG} -t semconv/template.j2 -s ${SPECTAG} -i ${SPECPATH}/model/. --only=resource -p conventionType=resource -f generated_resource.go
	$(SEMCONVGEN) -o semconv/${SPECTAG} -t semconv/template.j2 -s ${SPECTAG} -i ${SPECPATH}/model/. --only=event -p conventionType=event -f generated_event.go
	$(SEMCONVGEN) -o semconv/${SPECTAG} -t semconv/template.j2 -s ${SPECTAG} -i ${SPECPATH}/model/. --only=span -p conventionType=trace -f generated_trace.go
	$(SEMCONVGEN) -o semconv/${SPECTAG} -t semconv/template.j2 -s ${SPECTAG} -i ${SPECPATH}/model/. --only=attribute_group -p conventionType=attribute_group -f generated_attribute_group.go
	$(SEMCONVKIT) -output "semconv/$(SPECTAG)" -tag "$(SPECTAG)"

ALL_MOD_PATHS := "" $(ALL_MODULES:.%=%)

# Checks that the HEAD of the contrib repo checked out in CONTRIB_PATH compiles
# against the current version of this repo.
.PHONY: check-contrib
check-contrib:
	@echo Setting contrib at $(CONTRIB_PATH) to use this core checkout
	@$(MAKE) -j2 -C $(CONTRIB_PATH) for-all CMD="$(GOCMD) mod edit \
		$(addprefix -replace ,$(join $(ALL_MOD_PATHS:%=go.opentelemetry.io/collector%=),$(ALL_MOD_PATHS:%=$(CURDIR)%)))"
	@$(MAKE) -j2 -C $(CONTRIB_PATH) gotidy

	@$(MAKE) generate-contrib

	@echo -e "\nRunning tests"
	@$(MAKE) -C $(CONTRIB_PATH) gotest

	@if [ -z "$(SKIP_RESTORE_CONTRIB)" ]; then \
		$(MAKE) restore-contrib; \
	fi

.PHONY: generate-contrib
generate-contrib:
	@echo -e "\nGenerating files in contrib"
	$(MAKE) -C $(CONTRIB_PATH) -B install-tools
	$(MAKE) -C $(CONTRIB_PATH) generate GROUP=all

# Restores contrib to its original state after running check-contrib.
.PHONY: restore-contrib
restore-contrib:
	@echo -e "\nRestoring contrib at $(CONTRIB_PATH) to its original state"
	@$(MAKE) -C $(CONTRIB_PATH) for-all CMD="$(GOCMD) mod edit \
		$(addprefix -dropreplace ,$(ALL_MOD_PATHS:%=go.opentelemetry.io/collector%))"
	@$(MAKE) -C $(CONTRIB_PATH) for-all CMD="$(GOCMD) mod tidy"

# List of directories where certificates are stored for unit tests.
CERT_DIRS := localhost|""|config/configgrpc/testdata \
             localhost|""|config/confighttp/testdata \
             example1|"-1"|config/configtls/testdata \
             example2|"-2"|config/configtls/testdata
cert-domain = $(firstword $(subst |, ,$1))
cert-suffix = $(word 2,$(subst |, ,$1))
cert-dir = $(word 3,$(subst |, ,$1))

# Generate certificates for unit tests relying on certificates.
.PHONY: certs
certs:
	$(foreach dir, $(CERT_DIRS), $(call exec-command, @internal/buildscripts/gen-certs.sh -o $(call cert-dir,$(dir)) -s $(call cert-suffix,$(dir)) -m $(call cert-domain,$(dir))))

# Generate certificates for unit tests relying on certificates without copying certs to specific test directories.
.PHONY: certs-dryrun
certs-dryrun:
	@internal/buildscripts/gen-certs.sh -d

# Verify existence of READMEs for components specified as default components in the collector.
.PHONY: checkdoc
checkdoc: $(CHECKFILE)
	$(CHECKFILE) --project-path $(CURDIR) --component-rel-path $(COMP_REL_PATH) --module-name $(MOD_NAME) --file-name "README.md"

# Construct new API state snapshots
.PHONY: apidiff-build
apidiff-build: $(APIDIFF)
	@$(foreach pkg,$(ALL_PKGS),$(call exec-command,./internal/buildscripts/gen-apidiff.sh -p $(pkg)))

# If we are running in CI, change input directory
ifeq ($(CI), true)
APICOMPARE_OPTS=$(COMPARE_OPTS)
else
APICOMPARE_OPTS=-d "./internal/data/apidiff"
endif

# Compare API state snapshots
.PHONY: apidiff-compare
apidiff-compare: $(APIDIFF)
	@$(foreach pkg,$(ALL_PKGS),$(call exec-command,./internal/buildscripts/compare-apidiff.sh -p $(pkg)))

.PHONY: multimod-verify
multimod-verify: $(MULTIMOD)
	@echo "Validating versions.yaml"
	$(MULTIMOD) verify

MODSET?=stable
.PHONY: multimod-prerelease
multimod-prerelease: $(MULTIMOD)
	$(MULTIMOD) prerelease -s=true -b=false -v ./versions.yaml -m ${MODSET}
	$(MAKE) gotidy

COMMIT?=HEAD
REMOTE?=git@github.com:open-telemetry/opentelemetry-collector.git
.PHONY: push-tags
push-tags: $(MULTIMOD)
	$(MULTIMOD) verify
	set -e; for tag in `$(MULTIMOD) tag -m ${MODSET} -c ${COMMIT} --print-tags | grep -v "Using" `; do \
		echo "pushing tag $${tag}"; \
		git push ${REMOTE} $${tag}; \
	done;

.PHONY: check-changes
check-changes: $(MULTIMOD)
	$(MULTIMOD) diff -p $(PREVIOUS_VERSION) -m $(MODSET)

.PHONY: prepare-release
prepare-release:
ifndef MODSET
	@echo "MODSET not defined"
	@echo "usage: make prepare-release RELEASE_CANDIDATE=<version eg 0.53.0> PREVIOUS_VERSION=<version eg 0.52.0> MODSET=beta"
	exit 1
endif
ifdef PREVIOUS_VERSION
	@echo "Previous version $(PREVIOUS_VERSION)"
else
	@echo "PREVIOUS_VERSION not defined"
	@echo "usage: make prepare-release RELEASE_CANDIDATE=<version eg 0.53.0> PREVIOUS_VERSION=<version eg 0.52.0> MODSET=beta"
	exit 1
endif
ifdef RELEASE_CANDIDATE
	@echo "Preparing ${MODSET} release $(RELEASE_CANDIDATE)"
else
	@echo "RELEASE_CANDIDATE not defined"
	@echo "usage: make prepare-release RELEASE_CANDIDATE=<version eg 0.53.0> PREVIOUS_VERSION=<version eg 0.52.0> MODSET=beta"
	exit 1
endif
	# ensure a clean branch
	git diff -s --exit-code || (echo "local repository not clean"; exit 1)
	# update files with new version
	sed -i.bak 's/$(PREVIOUS_VERSION)/$(RELEASE_CANDIDATE)/g' versions.yaml
	sed -i.bak 's/$(PREVIOUS_VERSION)/$(RELEASE_CANDIDATE)/g' ./cmd/builder/internal/builder/config.go
	sed -i.bak 's/$(PREVIOUS_VERSION)/$(RELEASE_CANDIDATE)/g' ./cmd/builder/test/core.builder.yaml
	sed -i.bak 's/$(PREVIOUS_VERSION)/$(RELEASE_CANDIDATE)/g' ./cmd/otelcorecol/builder-config.yaml
	sed -i.bak 's/$(PREVIOUS_VERSION)/$(RELEASE_CANDIDATE)/g' examples/k8s/otel-config.yaml
	find . -name "*.bak" -type f -delete
	# commit changes before running multimod
	git add .
	git commit -m "prepare release $(RELEASE_CANDIDATE)"
	$(MAKE) multimod-prerelease
	# regenerate files
	$(MAKE) -C cmd/builder config
	$(MAKE) genotelcorecol
	git add .
	git commit -m "add multimod changes $(RELEASE_CANDIDATE)" || (echo "no multimod changes to commit")

.PHONY: clean
clean:
	test -d bin && $(RM) bin/*

.PHONY: checklinks
checklinks:
	command -v $(DOCKERCMD) >/dev/null 2>&1 || { echo >&2 "$(DOCKERCMD) not installed. Install before continuing"; exit 1; }
	$(DOCKERCMD) run -w /home/repo --rm \
		--mount 'type=bind,source='$(PWD)',target=/home/repo' \
		lycheeverse/lychee \
		--config .github/lychee.toml \
		--root-dir /home/repo \
		-v \
		--no-progress './**/*.md'

# error message "failed to sync logger:  sync /dev/stderr: inappropriate ioctl for device"
# is a known issue but does not affect function.
.PHONY: crosslink
crosslink: $(CROSSLINK)
	@echo "Executing crosslink"
	$(CROSSLINK) --root=$(shell pwd) --prune

FILENAME?=$(shell git branch --show-current)
.PHONY: chlog-new
chlog-new: $(CHLOGGEN)
	$(CHLOGGEN) new --config $(CHLOGGEN_CONFIG) --filename $(FILENAME)

.PHONY: chlog-validate
chlog-validate: $(CHLOGGEN)
	$(CHLOGGEN) validate --config $(CHLOGGEN_CONFIG)

.PHONY: chlog-preview
chlog-preview: $(CHLOGGEN)
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --dry

.PHONY: chlog-update
chlog-update: $(CHLOGGEN)
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --version $(VERSION)

.PHONY: builder-integration-test
builder-integration-test: $(ENVSUBST)
	cd ./cmd/builder && ./test/test.sh

.PHONY: mdatagen-test
mdatagen-test:
	cd cmd/mdatagen && $(GOCMD) install .
	cd cmd/mdatagen && $(GOCMD) generate ./...
	cd cmd/mdatagen && $(MAKE) fmt
	cd cmd/mdatagen && $(GOCMD) test ./...

.PHONY: generate-gh-issue-templates
generate-gh-issue-templates: $(GITHUBGEN)
	$(GITHUBGEN) issue-templates

.PHONY: generate-codeowners
generate-codeowners: $(GITHUBGEN)
	$(GITHUBGEN) --default-codeowner "open-telemetry/collector-approvers" codeowners

.PHONY: gengithub
gengithub: $(GITHUBGEN) generate-codeowners generate-gh-issue-templates

.PHONY: gendistributions
gendistributions: $(GITHUBGEN)
	$(GITHUBGEN) distributions

# ===== GENERATED_START =====
# =========================================
# TCS Template Generated Content (2025-12-30T15:58:57+08:00)
# =========================================

# Auto-detect system architecture
ARCH := $(shell uname -m)

# Project name (can be overridden)
PROJECT_NAME ?= custom-otlp-collector

# Map system architecture to Docker architecture
ifeq ($(ARCH),x86_64)
	DOCKER_ARCH = amd64
else ifeq ($(ARCH),aarch64)
	DOCKER_ARCH = arm64
else ifeq ($(ARCH),arm64)
	DOCKER_ARCH = arm64
else
	$(error Unsupported architecture: $(ARCH))
endif

# Generate Dockerfile name based on project and architecture
DOCKERFILE ?= Dockerfile.$(PROJECT_NAME).$(DOCKER_ARCH)

# MINIKUBE flag (default: 0)
MINIKUBE ?= 0

# Docker compose command prefix
ifeq ($(MINIKUBE),1)
	COMPOSE_PREFIX = MINIKUBE=1
else
	COMPOSE_PREFIX =
endif

# Docker compose command with env-file and architecture
COMPOSE_CMD = $(COMPOSE_PREFIX) DOCKERFILE=$(DOCKERFILE) DOCKER_ARCH=$(DOCKER_ARCH) docker compose --env-file .env.make

.PHONY: help clean docker-build docker-up docker-down docker-restart .env.make arch-info \
		check-tools check-kompose check-kubectl \
		k8s-convert k8s-deploy k8s-clean cicd-deploy \
		k8s-status k8s-logs

# Default target
.DEFAULT_GOAL := help

# Show help information
help:
	@echo "========================================="
	@echo "TCS Service Template - Makefile Commands"
	@echo "========================================="
	@echo ""
	@echo "📦 Docker Commands:"
	@echo "  make docker-build          Build Docker image"
	@echo "  make docker-up             Start services with docker compose"
	@echo "  make docker-down           Stop services"
	@echo "  make docker-restart        Rebuild and restart services"
	@echo ""
	@echo "🔧 Tool Check Commands:"
	@echo "  make check-tools           Check all required CI/CD tools"
	@echo "  make check-kompose         Check kompose installation"
	@echo "  make check-kubectl         Check kubectl installation"
	@echo ""
	@echo "☸️  Kubernetes Commands:"
	@echo "  make k8s-convert           Convert compose.yaml to K8s manifests"
	@echo "  make k8s-deploy            Deploy to K8s cluster"
	@echo "  make k8s-full-deploy       Full deployment with ConfigMap (recommended)"
	@echo "  make k8s-status            Check deployment status"
	@echo "  make k8s-logs              View application logs"
	@echo "  make k8s-clean             Clean up K8s resources"
	@echo ""
	@echo "📝 ConfigMap Commands:"
	@echo "  make k8s-configmap         Create ConfigMap from config directory"
	@echo ""
	@echo "🚀 CI/CD Commands:"
	@echo "  make cicd-deploy           Full CI/CD pipeline (build -> convert -> deploy)"
	@echo ""
	@echo "ℹ️  Information Commands:"
	@echo "  make arch-info             Show architecture detection information"
	@echo "  make help                  Show this help message"
	@echo ""
	@echo "🔧 Configuration Variables:"
	@echo "  PROJECT_NAME               Project name (default: custom-otlp-collector)"
	@echo "  K8S_NAMESPACE              Kubernetes namespace (default: default)"
	@echo "  K8S_OUTPUT_DIR             Output directory (default: k8s-manifests)"
	@echo "  K8S_VOLUME_TYPE            Volume type (default: configMap)"
	@echo "                             Options: configMap, persistentVolumeClaim, emptyDir, hostPath"
	@echo "  K8S_CONFIGMAP_NAME         ConfigMap name (default: \${PROJECT_NAME}-config)"
	@echo "  K8S_CONFIG_DIR             Config directory (default: ./.tad/build/custom-otlp-collector/build)"
	@echo "  MINIKUBE                   Minikube mode (default: 0)"
	@echo "  DOCKER_ARCH                Docker architecture (auto-detected)"
	@echo ""
	@echo "📚 Examples:"
	@echo "  make k8s-full-deploy K8S_NAMESPACE=dev"
	@echo "  make k8s-status K8S_NAMESPACE=production"
	@echo "  make k8s-convert K8S_VOLUME_TYPE=persistentVolumeClaim"
	@echo "  make cicd-deploy K8S_VOLUME_TYPE=emptyDir"
	@echo "  make docker-build MINIKUBE=1"
	@echo ""
	@echo "📖 Documentation:"
	@echo "  See docs/K8S_CONFIG_GUIDE.md for detailed guide"
	@echo "  See docs/K8S_QUICK_REFERENCE.md for quick reference"
	@echo "========================================="

# Show architecture information
arch-info:
	@echo "========================================="
	@echo "Architecture Detection Information"
	@echo "========================================="
	@echo "System Architecture: $(ARCH)"
	@echo "Docker Architecture: $(DOCKER_ARCH)"
	@echo "Dockerfile: $(DOCKERFILE)"
	@echo "MINIKUBE Mode: $(MINIKUBE)"
	@echo "========================================="

# ============================================
# CI/CD Tool Detection
# ============================================

# Check if a command exists
check-cmd-%:
	@command -v $* >/dev/null 2>&1 || { \
		echo "ERROR: Required tool '$*' is not installed"; \
		echo "Please install '$*' before proceeding"; \
		exit 1; \
	}
	@echo "✓ $* is available"

# Check all required tools for CI/CD
check-tools: check-cmd-docker check-cmd-kompose check-cmd-kubectl
	@echo "========================================="
	@echo "All required CI/CD tools are available"
	@echo "========================================="

# Check kompose specifically
check-kompose:
	@command -v kompose >/dev/null 2>&1 || { \
		echo "ERROR: kompose is not installed"; \
		echo ""; \
		echo "Installation instructions:"; \
		echo "  macOS:   brew install kompose"; \
		echo "  Linux:   curl -L https://github.com/kubernetes/kompose/releases/download/v1.31.2/kompose-linux-amd64 -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose"; \
		echo "  Windows: choco install kubernetes-kompose"; \
		echo ""; \
		echo "Or visit: https://kompose.io/installation/"; \
		exit 1; \
	}
	@echo "✓ kompose is available (version: $(kompose version 2>/dev/null | head -n1 || echo 'unknown'))"

# Check kubectl specifically
check-kubectl:
	@command -v kubectl >/dev/null 2>&1 || { \
		echo "ERROR: kubectl is not installed"; \
		echo ""; \
		echo "Installation instructions:"; \
		echo "  macOS:   brew install kubectl"; \
		echo "  Linux:   curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"; \
		echo "  Windows: choco install kubernetes-cli"; \
		echo ""; \
		echo "Or visit: https://kubernetes.io/docs/tasks/tools/"; \
		exit 1; \
	}
	@echo "✓ kubectl is available (version: $(kubectl version --client --short 2>/dev/null || echo 'unknown'))"
	@kubectl cluster-info >/dev/null 2>&1 || { \
		echo "WARNING: kubectl is installed but cannot connect to a cluster"; \
		echo "Please ensure your kubeconfig is properly configured"; \
	}

clean:
	rm -rf bin/custom-otlp-collector
	rm -f .env.make


# Generate .env.make from .tad/devops.yaml
.env.make:
	@echo "# Auto-generated from .tad/devops.yaml" > .env.make
	@grep -A 100 "export_envs:" .tad/devops.yaml | \
		grep -E "^\s+- name:|^\s+value:" | \
		sed 'N;s/.*name: "\(.*\)".* value: "\(.*\)".*/\1=\2/' >> .env.make || true
	@echo "" >> .env.make
	@echo "# Architecture-specific variables" >> .env.make
	@echo "DOCKERFILE=$(DOCKERFILE)" >> .env.make
	@echo "DOCKER_ARCH=$(DOCKER_ARCH)" >> .env.make
	@echo ".env.make generated successfully (Architecture: $(ARCH) -> $(DOCKER_ARCH))"

# Build with docker compose
docker-build: .env.make
	@echo "Building with docker compose (Architecture: $(ARCH) -> $(DOCKER_ARCH), MINIKUBE=$(MINIKUBE))..."
	@echo "Using Dockerfile: $(DOCKERFILE)"
	$(COMPOSE_CMD) build

# Start services with docker compose
docker-up: .env.make
	@echo "Starting services with docker compose (MINIKUBE=$(MINIKUBE))..."
	$(COMPOSE_CMD) up -d

# Stop services
docker-down:
	@echo "Stopping services..."
	docker compose down

# Rebuild and restart
docker-restart: docker-down docker-build docker-up

# ============================================
# Kubernetes Deployment Commands
# ============================================

# K8s output directory
K8S_OUTPUT_DIR ?= k8s-manifests
K8S_NAMESPACE ?= default
K8S_CONFIGMAP_NAME ?= $(PROJECT_NAME)-config
K8S_CONFIG_DIR ?= ./.tad/build/custom-otlp-collector/build

# Volume type for kompose conversion
# Options: configMap (default), persistentVolumeClaim, emptyDir, hostPath
K8S_VOLUME_TYPE ?= configMap

# Convert docker-compose to k8s manifests
k8s-convert: check-kompose .env.make
	@echo "========================================="
	@echo "Converting Docker Compose to K8s manifests"
	@echo "========================================="
	@echo "Output directory: $(K8S_OUTPUT_DIR)"
	@echo "Volume type: $(K8S_VOLUME_TYPE)"
	@mkdir -p $(K8S_OUTPUT_DIR)
	@echo "Running kompose convert..."
	@cd $(K8S_OUTPUT_DIR) && \
		DOCKERFILE=$(DOCKERFILE) DOCKER_ARCH=$(DOCKER_ARCH) \
		kompose convert -f ../compose.yaml --volumes $(K8S_VOLUME_TYPE) || { \
		echo "ERROR: kompose convert failed"; \
		exit 1; \
	}
	@echo "✓ K8s manifests generated successfully in $(K8S_OUTPUT_DIR)/"
	@echo ""
	@echo "Generated files:"
	@ls -lh $(K8S_OUTPUT_DIR)/
	@echo ""
	@if [ "$(K8S_VOLUME_TYPE)" = "configMap" ]; then \
		echo "ℹ️  Note: ConfigMap volumes generated. You may need to:"; \
		echo "   1. Create ConfigMaps with actual config data"; \
		echo "   2. Run 'make k8s-configmap' to generate from files"; \
	elif [ "$(K8S_VOLUME_TYPE)" = "persistentVolumeClaim" ]; then \
		echo "ℹ️  Note: PVC volumes generated. You may need to:"; \
		echo "   1. Create PersistentVolumes in your cluster"; \
		echo "   2. Adjust storage class and size in PVC manifests"; \
	elif [ "$(K8S_VOLUME_TYPE)" = "emptyDir" ]; then \
		echo "ℹ️  Note: emptyDir volumes generated (ephemeral storage)"; \
		echo "   Data will be lost when pod restarts"; \
	fi
	@echo "========================================="

# Deploy to k8s cluster
k8s-deploy: check-kubectl k8s-convert
	@echo "========================================="
	@echo "Deploying to Kubernetes cluster"
	@echo "========================================="
	@if [ ! -d "$(K8S_OUTPUT_DIR)" ] || [ -z "$$(ls -A $(K8S_OUTPUT_DIR) 2>/dev/null)" ]; then \
		echo "ERROR: K8s manifests not found in $(K8S_OUTPUT_DIR)/"; \
		echo "Please run 'make k8s-convert' first"; \
		exit 1; \
	fi
	@echo "Namespace: $(K8S_NAMESPACE)"
	@echo "Applying manifests from $(K8S_OUTPUT_DIR)/..."
	@kubectl apply -f $(K8S_OUTPUT_DIR)/ -n $(K8S_NAMESPACE) || { \
		echo "ERROR: kubectl apply failed"; \
		echo "Please check your cluster connection and manifests"; \
		exit 1; \
	}
	@echo "✓ Deployment successful"
	@echo ""
	@echo "Checking deployment status..."
	@kubectl get all -n $(K8S_NAMESPACE) -l io.kompose.service=$(PROJECT_NAME) 2>/dev/null || \
		kubectl get all -n $(K8S_NAMESPACE) | grep $(PROJECT_NAME) || \
		echo "Note: Use 'kubectl get all -n $(K8S_NAMESPACE)' to check all resources"
	@echo "========================================="

# Clean k8s resources
k8s-clean: check-kubectl
	@echo "========================================="
	@echo "Cleaning Kubernetes resources"
	@echo "========================================="
	@if [ ! -d "$(K8S_OUTPUT_DIR)" ] || [ -z "$$(ls -A $(K8S_OUTPUT_DIR) 2>/dev/null)" ]; then \
		echo "WARNING: K8s manifests not found in $(K8S_OUTPUT_DIR)/"; \
		echo "Skipping kubectl delete"; \
	else \
		echo "Deleting resources from $(K8S_OUTPUT_DIR)/..."; \
		kubectl delete -f $(K8S_OUTPUT_DIR)/ -n $(K8S_NAMESPACE) --ignore-not-found=true || { \
			echo "WARNING: Some resources may not have been deleted"; \
		}; \
		echo "✓ Resources deleted"; \
	fi
	@echo "Removing local manifests directory..."
	@rm -rf $(K8S_OUTPUT_DIR)
	@echo "✓ Local manifests cleaned"
	@echo "========================================="


# Check deployment status
k8s-status: check-kubectl
	@echo "========================================="
	@echo "Kubernetes Deployment Status"
	@echo "========================================="
	@echo "Namespace: $(K8S_NAMESPACE)"
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n $(K8S_NAMESPACE) -l io.kompose.service=$(PROJECT_NAME) 2>/dev/null || \
		kubectl get pods -n $(K8S_NAMESPACE) | grep $(PROJECT_NAME) || \
		echo "No pods found for $(PROJECT_NAME)"
	@echo ""
	@echo "Services:"
	@kubectl get svc -n $(K8S_NAMESPACE) -l io.kompose.service=$(PROJECT_NAME) 2>/dev/null || \
		kubectl get svc -n $(K8S_NAMESPACE) | grep $(PROJECT_NAME) || \
		echo "No services found for $(PROJECT_NAME)"
	@echo ""
	@echo "ConfigMaps:"
	@kubectl get configmap $(K8S_CONFIGMAP_NAME) -n $(K8S_NAMESPACE) 2>/dev/null || \
		echo "ConfigMap $(K8S_CONFIGMAP_NAME) not found"
	@echo "========================================="

# View logs
k8s-logs: check-kubectl
	@echo "========================================="
	@echo "Fetching logs for $(PROJECT_NAME)"
	@echo "========================================="
	@pod=$$(kubectl get pods -n $(K8S_NAMESPACE) -l io.kompose.service=$(PROJECT_NAME) -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$pod" ]; then \
		pod=$$(kubectl get pods -n $(K8S_NAMESPACE) -o name | grep $(PROJECT_NAME) | head -n1 | cut -d'/' -f2); \
	fi; \
	if [ -z "$$pod" ]; then \
		echo "ERROR: No pods found for $(PROJECT_NAME)"; \
		exit 1; \
	fi; \
	echo "Pod: $$pod"; \
	echo ""; \
	kubectl logs -f $$pod -n $(K8S_NAMESPACE)


# Full CI/CD pipeline: build -> convert -> deploy (basic)
cicd-deploy: check-tools docker-build k8s-convert k8s-deploy
	@echo "========================================="
	@echo "CI/CD Pipeline Completed Successfully"
	@echo "========================================="
	@echo "Project: $(PROJECT_NAME)"
	@echo "Architecture: $(ARCH) -> $(DOCKER_ARCH)"
	@echo "Namespace: $(K8S_NAMESPACE)"
	@echo "Volume Type: $(K8S_VOLUME_TYPE)"
	@echo ""
	@if [ "$(K8S_VOLUME_TYPE)" = "hostPath" ]; then \
		echo "⚠️  WARNING: Using hostPath volumes (not recommended for production)"; \
		echo "Consider using: K8S_VOLUME_TYPE=configMap or persistentVolumeClaim"; \
	elif [ "$(K8S_VOLUME_TYPE)" = "configMap" ]; then \
		echo "✓ Using ConfigMap volumes (recommended for config files)"; \
		echo "For full ConfigMap support, use: make k8s-full-deploy"; \
	elif [ "$(K8S_VOLUME_TYPE)" = "persistentVolumeClaim" ]; then \
		echo "✓ Using PersistentVolumeClaim (recommended for data persistence)"; \
		echo "Ensure PVs are available in your cluster"; \
	elif [ "$(K8S_VOLUME_TYPE)" = "emptyDir" ]; then \
		echo "ℹ️  Using emptyDir volumes (ephemeral storage)"; \
		echo "Data will be lost when pod restarts"; \
	fi
	@echo ""
	@echo "Next steps:"
	@echo "  - Check status: make k8s-status"
	@echo "  - View logs: make k8s-logs"
	@echo "  - Clean up: make k8s-clean"
	@echo "========================================="

# ============================================
# Custom Targets
# ============================================

.PHONY: test
test: ## Run tests
	go test -v ./...

.PHONY: lint
lint: ## Run linter
	golangci-lint run 
# ===== GENERATED_END =====
