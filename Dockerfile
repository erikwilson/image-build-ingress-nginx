ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.15.8b5

ARG CURL_VERSION=curl-7_75_0

ARG TAG=v0.35.0
ARG ARCH="amd64"
ARG PKG=k8s.io/ingress-nginx
ARG SRC=github.com/kubernetes/ingress-nginx
ARG MAJOR
ARG MINOR

FROM ${UBI_IMAGE} as ubi


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

ADD ./artifacts/boringssl.tar.gz /usr/local/boringssl/

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

RUN rm -rf /usr/local/*

ADD ./artifacts/boringssl.tar.gz /usr/local/
COPY --from=curl-builder /usr/local/curl/ /usr/local/

COPY ./patches/nginx/* /patches/
COPY ./src/${PKG} ${GOPATH}/src/${PKG}
WORKDIR ${GOPATH}/src/${PKG}
RUN cp ./images/nginx/rootfs/patches/* /patches/

WORKDIR /tmp
RUN cp ${GOPATH}/src/${PKG}/images/nginx/rootfs/build.sh .
RUN ./build.sh


#--- build hardened ingress-nginx with goboring ---
FROM ${GO_IMAGE} as ingress-nginx-builder
# setup the build
ARG TAG
ARG PKG
ARG SRC
ENV BUILD_TAG=controller-${TAG}
RUN git clone --depth=1 --branch ${BUILD_TAG} https://${SRC}.git ${GOPATH}/src/${PKG}
WORKDIR ${GOPATH}/src/${PKG}

RUN apk add dumb-init
RUN file /usr/bin/dumb-init | grep 'statically linked'

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
FROM ubi as build

WORKDIR /etc/nginx

RUN microdnf update -y && rm -rf /var/cache/yum
RUN microdnf install -y conntrack-tools findutils which

RUN groupadd --system --gid 101 www-data \
    && adduser --system -g www-data --no-create-home --home /nonexistent -c "www-data user" --shell /bin/false --uid 101 www-data

ENV PATH=$PATH:/usr/local/luajit/bin:/usr/local/nginx/sbin:/usr/local/nginx/bin

ENV LUA_PATH="/usr/local/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/lib/lua/?.lua;;"
ENV LUA_CPATH="/usr/local/lib/lua/?/?.so;/usr/local/lib/lua/?.so;;"

COPY --from=nginx-builder --chown=www-data:www-data /etc/nginx/ /etc/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /usr/local/nginx/ /usr/local/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /usr/local/lib/lua/ /usr/local/lib/lua/
COPY --from=nginx-builder --chown=www-data:www-data /opt/modsecurity/ /opt/modsecurity/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/audit/ /var/log/audit/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/nginx/ /var/log/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/rootfs/etc/nginx/ /etc/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/images/nginx/rootfs/etc/nginx/geoip/ /etc/nginx/geoip/

RUN bash -eu -c ' \
  writeDirs=( \
    /var/lib/nginx/body \
    /var/lib/nginx/fastcgi \
    /var/lib/nginx/proxy \
    /var/lib/nginx/scgi \
    /var/lib/nginx/uwsgi \
    /etc/ingress-controller \
    /etc/ingress-controller/ssl \
    /etc/ingress-controller/auth \
  ); \
  for dir in "${writeDirs[@]}"; do \
    mkdir -p ${dir}; \
    chown -R www-data.www-data ${dir}; \
  done'

RUN mkdir -p /var/cache/nginx && \
    chown -R www-data:0 /var/cache/nginx && \
    chmod -R g=u /var/cache/nginx

COPY --from=ingress-nginx-builder --chown=www-data:www-data /usr/local/bin/ /
COPY --from=ingress-nginx-builder /usr/bin/dumb-init /usr/local/bin/dumb-init

RUN setcap    cap_net_bind_service=+ep /nginx-ingress-controller
RUN setcap -v cap_net_bind_service=+ep /nginx-ingress-controller
RUN setcap    cap_net_bind_service=+ep /usr/local/nginx/sbin/nginx
RUN setcap -v cap_net_bind_service=+ep /usr/local/nginx/sbin/nginx

USER www-data

RUN /nginx-ingress-controller --version

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]

CMD ["/nginx-ingress-controller"]
