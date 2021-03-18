SEVERITIES = HIGH,CRITICAL

ifeq ($(ARCH),)
ARCH=$(shell go env GOARCH)
endif

BUILD_META=-build$(shell date +%Y%m%d)
ORG ?= rancher
PKG ?= k8s.io/ingress-nginx
SRC ?= github.com/kubernetes/ingress-nginx
TAG ?= v0.35.0$(BUILD_META)

SUBMODULES ?= $(shell git submodule--helper list | cut -f2)

ifneq ($(DRONE_TAG),)
TAG := $(DRONE_TAG)
endif

ifeq (,$(filter %$(BUILD_META),$(TAG)))
$(error TAG needs to end with build metadata: $(BUILD_META))
endif

.PHONY: image-build
image-build: src artifacts/boringssl
	docker build --target nginx-builder \
		--pull \
		--target nginx-builder \
		--progress plain \
		--build-arg ARCH=$(ARCH) \
		--build-arg PKG=$(PKG) \
		--build-arg SRC=$(SRC) \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		--build-arg MAJOR=$(shell ./scripts/semver-parse.sh ${TAG} major) \
		--build-arg MINOR=$(shell ./scripts/semver-parse.sh ${TAG} minor) \
		--tag $(ORG)/hardened-ingress-nginx:$(TAG) \
		--tag $(ORG)/hardened-ingress-nginx:$(TAG)-$(ARCH) \
	.

artifacts:
	mkdir artifacts

artifacts/boringssl: artifacts
	docker build --tag boringssl${BUILD_META} src/go.googlesource.com/go-boring/src/crypto/internal/boring/
	docker create --name boringssl${BUILD_META} boringssl${BUILD_META}
	docker cp boringssl${BUILD_META}:/usr/local/boringssl/ $@
	docker rm boringssl${BUILD_META}

.PHONY: git-submodule-update
git-submodule-update:
	git submodule update

.PHONY: ${SUBMODULES}
${SUBMODULES}: git-submodule-update
	@set -o xtrace; \
	PKG=$(@:src/%=%); \
	if [ -n "$$(git -C $@ status --porcelain --untracked-files=no)" ]; then \
		git -C $@ diff -p -U2 > patches/$${PKG}.patch; \
	else \
		patch -d $@ -p1 < patches/$${PKG}.patch; \
	fi

.PHONY: src
src: ${SUBMODULES}

.PHONY: image-push
image-push:
	docker push $(ORG)/hardened-ingress-nginx:$(TAG)-$(ARCH)

.PHONY: image-manifest
image-manifest:
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create --amend \
		$(ORG)/hardened-ingress-nginx:$(TAG) \
		$(ORG)/hardened-ingress-nginx:$(TAG)-$(ARCH)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push \
		$(ORG)/hardened-ingress-nginx:$(TAG)

.PHONY: image-scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --ignore-unfixed $(ORG)/hardened-ingress-nginx:$(TAG)
