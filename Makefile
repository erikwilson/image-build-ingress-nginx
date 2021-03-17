SEVERITIES = HIGH,CRITICAL

ifeq ($(ARCH),)
ARCH=$(shell go env GOARCH)
endif

BUILD_META=-build$(shell date +%Y%m%d)
ORG ?= rancher
PKG ?= k8s.io/ingress-nginx
SRC ?= github.com/kubernetes/ingress-nginx
TAG ?= v0.35.0$(BUILD_META)

ifneq ($(DRONE_TAG),)
TAG := $(DRONE_TAG)
endif

ifeq (,$(filter %$(BUILD_META),$(TAG)))
$(error TAG needs to end with build metadata: $(BUILD_META))
endif

.PHONY: image-build
image-build: src patches
	docker build --target curl-builder \
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

boring/build.sh:
	curl -fSL https://raw.githubusercontent.com/golang/go/dev.boringcrypto.go1.16/src/crypto/internal/$@ -o $@
	chmod a+x $@

boring/goboringcrypto.h:
	curl -fSL https://raw.githubusercontent.com/golang/go/dev.boringcrypto.go1.16/src/crypto/internal/$@ -o $@

boring: \
	boring/build.sh \
	boring/goboringcrypto.h

.PHONY: patches/${PKG}.patch
patches/${PKG}.patch: src
	if [ -n "$(shell git -C ./src/${PKG} status --porcelain --untracked-files=no)" ]; then \
		git -C ./src/${PKG} diff -p -U2 > $@; \
	else \
		patch -d ./src/${PKG} -p1 < $@; \
	fi

.PHONY: src
src: boring
	git submodule update

patches: \
	patches/${PKG}.patch

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
