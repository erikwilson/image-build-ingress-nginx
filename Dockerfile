ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.15.8b5
FROM ${UBI_IMAGE} as ubi
FROM ${GO_IMAGE} as builder
# setup required packages
RUN set -x \
 && apk --no-cache add \
    file \
    gcc \
    git \
    make
# setup the build
ARG ARCH="amd64"
ARG TAG=controller-v0.35.0
ARG PKG=k8s.io/ingress-nginx
ARG SRC=github.com/kubernetes/ingress-nginx
ARG MAJOR
ARG MINOR
RUN git clone --depth=1 https://${SRC}.git $GOPATH/src/${PKG}
WORKDIR $GOPATH/src/${PKG}
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}

RUN \
    export COMMIT=$(git rev-parse --short HEAD) && \
    export REPO_INFO=$(git config --get remote.origin.url) && \
    export GO_LDFLAGS="-linkmode=external \
        -X ${PKG}/version.RELEASE=${TAG} \
        -X ${PKG}/version.COMMIT=${COMMIT} \
        -X ${PKG}/version.REPO=${REPO_INFO} \
    " && \
    go-build-static.sh -o "bin/nginx-ingress-controller" "${PKG}/cmd/nginx" && \
    go-build-static.sh -o "bin/dbg" "${PKG}/cmd/dbg" && \
    go-build-static.sh -o "bin/wait-shutdown" "${PKG}/cmd/waitshutdown"

RUN go-assert-static.sh bin/*
RUN go-assert-boring.sh bin/*
# install (with strip) to /usr/local/bin
RUN install -s bin/* /usr/local/bin

FROM ubi
COPY nginx.repo /etc/yum.repos.d/nginx.repo
RUN microdnf update -y && \
    microdnf install -y conntrack-tools findutils nginx which
RUN mkdir -p /var/cache/nginx && \
    chown -R nginx:0 /var/log/nginx/ /var/cache/nginx /usr/share/nginx && \
    chmod -R g=u /var/log/nginx/ /var/cache/nginx /usr/share/nginx && \
    rm -rf /var/cache/yum
COPY --from=builder /usr/local/bin/ /usr/local/bin/
RUN nginx-ingress-controller --version
