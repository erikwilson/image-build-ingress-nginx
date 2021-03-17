ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.15.8b5

ARG BORING_VERSION=fips-20190808
ARG CURL_VERSION=curl-7_75_0

ARG TAG=v0.35.0
ARG ARCH="amd64"
ARG PKG=k8s.io/ingress-nginx
ARG SRC=github.com/kubernetes/ingress-nginx
ARG MAJOR
ARG MINOR

FROM ${UBI_IMAGE} as ubi


#--- boringssl build adapted from https://github.com/golang/go/blob/dev.boringcrypto.go1.16/src/crypto/internal/boring/Dockerfile ---
FROM ubuntu:focal as boringssl-builder

RUN mkdir /boring
WORKDIR /boring

# Following 140sp3678.pdf [0] page 19, install clang 7.0.1, Go 1.12.7, and
# Ninja 1.9.0, then download and verify BoringSSL.
#
# [0]: https://csrc.nist.gov/CSRC/media/projects/cryptographic-module-validation-program/documents/security-policies/140sp3678.pdf

RUN apt-get update && \
        apt-get install --no-install-recommends -y cmake xz-utils wget unzip ca-certificates clang-7
RUN wget https://github.com/ninja-build/ninja/releases/download/v1.9.0/ninja-linux.zip && \
        unzip ninja-linux.zip && \
        rm ninja-linux.zip && \
        mv ninja /usr/local/bin/
RUN wget https://golang.org/dl/go1.12.7.linux-amd64.tar.gz && \
        tar -C /usr/local -xzf go1.12.7.linux-amd64.tar.gz && \
        rm go1.12.7.linux-amd64.tar.gz && \
        ln -s /usr/local/go/bin/go /usr/local/bin/

RUN wget https://commondatastorage.googleapis.com/chromium-boringssl-fips/boringssl-ae223d6138807a13006342edfeef32e813246b39.tar.xz
RUN [ "$(sha256sum boringssl-ae223d6138807a13006342edfeef32e813246b39.tar.xz | awk '{print $1}')" = \
        3b5fdf23274d4179c2077b5e8fa625d9debd7a390aac1d165b7e47234f648bb8 ]

ADD boring/goboringcrypto.h /boring/godriver/goboringcrypto.h
ADD boring/build.sh /boring/build.sh
RUN ./build.sh

RUN install -d /usr/local/boringssl/include/openssl/ /usr/local/boringssl/lib/
RUN install ./boringssl/include/openssl/* /usr/local/boringssl/include/openssl/
RUN install ./boringssl/build/crypto/libcrypto.a /usr/local/boringssl/lib/
RUN install ./boringssl/build/ssl/libssl.a /usr/local/boringssl/lib/


#--- build curl with boringssl ---
FROM ${GO_IMAGE} as curl-builder

RUN apk add \
        autoconf \
        automake \
        libtool \
        pkgconf \
        brotli-dev \
        nghttp2-dev \
        zlib-dev \
        zstd-dev

ARG CURL_VERSION
ENV CURL_SRC=/usr/src/curl
RUN git clone --depth=1 --branch ${CURL_VERSION} https://github.com/curl/curl.git ${CURL_SRC}
WORKDIR ${CURL_SRC}

COPY --from=boringssl-builder /usr/local/boringssl/ /usr/local/boringssl/

RUN autoreconf -fi
RUN ./configure \
        --enable-shared=no \
        --with-ssl=/usr/local/boringssl \
        --prefix=/usr/local/curl
RUN make
RUN make install


#--- build hardened nginx with boringssl ---
FROM ${GO_IMAGE} as nginx-builder

RUN apk add \
        patch \
        brotli-dev \
        brotli-static \
        bzip2-static \
        libxslt-dev \
        libmaxminddb-static \
        nghttp2-static \
        zlib-static \
        zstd-static

RUN deluser svn
RUN delgroup svnusers
RUN delgroup docker

ARG PKG
ARG SRC

ENV CC=cc
ENV CXX=c++

COPY --from=boringssl-builder /usr/local/boringssl/ /usr/local/
COPY --from=curl-builder /usr/local/curl/ /usr/local/

COPY ./patches/nginx/* /patches/
COPY ./src/${PKG} ${GOPATH}/src/${PKG}
WORKDIR ${GOPATH}/src/${PKG}
RUN cp ./images/nginx/rootfs/patches/* /patches/

WORKDIR /usr/src
RUN ${GOPATH}/src/${PKG}/images/nginx/rootfs/build.sh


#--- build hardened ingress-nginx with goboring ---
FROM ${GO_IMAGE} as ingress-nginx-builder
# setup the build
ARG TAG
ARG PKG
ARG SRC
ENV BUILD_TAG=controller-${TAG}
RUN git clone --depth=1 --branch ${BUILD_TAG} https://${SRC}.git ${GOPATH}/src/${PKG}
WORKDIR ${GOPATH}/src/${PKG}

RUN \
    export COMMIT=$(git rev-parse --short HEAD) && \
    export REPO_INFO=$(git config --get remote.origin.url) && \
    export GO_LDFLAGS="-linkmode=external \
        -X ${PKG}/version.RELEASE=${BUILD_TAG} \
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


#--- create a runtime image ---
FROM ubi

WORKDIR /

RUN microdnf update -y && rm -rf /var/cache/yum
RUN microdnf install -y conntrack-tools findutils which

RUN groupadd --system --gid 101 www-data \
    && adduser --system -g www-data --no-create-home --home /nonexistent -c "www-data user" --shell /bin/false --uid 101 www-data

COPY --from=nginx-builder --chown=www-data:www-data /etc/nginx/ /etc/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /usr/local/nginx/ /usr/local/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /opt/modsecurity/ /opt/modsecurity/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/audit/ /var/log/audit/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/nginx/ /var/log/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/rootfs/etc/nginx/ /etc/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/images/nginx/rootfs/etc/nginx/geoip/ /etc/nginx/geoip/

RUN mkdir -p /var/cache/nginx && \
    chown -R www-data:0 /var/cache/nginx && \
    chmod -R g=u /var/cache/nginx

COPY --from=ingress-nginx-builder --chown=www-data:www-data /usr/local/bin/ /usr/local/bin/

RUN ln -s /usr/local/bin/* .
RUN ln -s /usr/local/nginx/sbin/* /usr/local/bin/

RUN for exec in $(ls /usr/local/bin/nginx*); do \
        setcap cap_net_bind_service=+ep $exec; \
        setcap -v cap_net_bind_service=+ep $exec || (echo "setcap for $exec failed" >&2; exit 1); \
    done

USER www-data

RUN nginx-ingress-controller --version
