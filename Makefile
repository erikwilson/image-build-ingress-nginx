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
image-build: patches
	docker build --target nginx-builder \
		--pull \
		--build-arg ARCH=$(ARCH) \
		--build-arg PKG=$(PKG) \
		--build-arg SRC=$(SRC) \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		--build-arg MAJOR=$(shell ./scripts/semver-parse.sh ${TAG} major) \
		--build-arg MINOR=$(shell ./scripts/semver-parse.sh ${TAG} minor) \
		--tag $(ORG)/hardened-ingress-nginx:$(TAG) \
		--tag $(ORG)/hardened-ingress-nginx:$(TAG)-$(ARCH) \
	.

patches/nginx-src-dynamic_tls_records.patch:
	curl -fSL https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/0.5/nginx__dynamic_tls_records_1.17.7%2B.patch -o patches/nginx-src-dynamic_tls_records.patch

.PHONY: src/patches/ingress-nginx.patch
src/patches/ingress-nginx.patch: src/ingress-nginx/images/nginx/rootfs/build.sh
	cd src/ingress-nginx && [ -n "$(git status --porcelain --untracked-files=no)" ] && \
		diff -p -U2 >../patches/ingress-nginx.patch

src/ingress-nginx/images/nginx/rootfs/build.sh:
	git submodule update
	cd src/ingress-nginx && patch -p1 <../patches/ingress-nginx.patch

patches: \
	patches/nginx-src-dynamic_tls_records.patch \
	src/patches/ingress-nginx.patch

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
