ARG GO_IMAGE=rancher/hardened-build-base:v1.15.8b5
ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG CENTOS_IMAGE=centos:7
ARG ALPINE_IMAGE=alpine:3.13.4

ARG CURL_VERSION=curl-7_75_0

ARG TAG=v0.35.0
ARG ARCH="amd64"
ARG PKG=k8s.io/ingress-nginx
ARG SRC=github.com/kubernetes/ingress-nginx
ARG MAJOR
ARG MINOR

ARG LUA_PATH="/usr/local/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/lib/lua/?.lua;;"
ARG LUA_CPATH="/usr/local/lib/lua/?/?.so;/usr/local/lib/lua/?.so;;"

ARG LOCAL=/opt/local
ARG CURL=/opt/curl

#------------------------------------------------------------------------------

FROM ${GO_IMAGE} as go

FROM ${UBI_IMAGE} as ubi

FROM ${CENTOS_IMAGE} as centos

FROM ${ALPINE_IMAGE} as alpine


#------------------------------------------------------------------------------
#--- build curl with boringssl ---
FROM alpine as curl-builder

RUN apk add \
        alpine-sdk \
        autoconf \
        automake \
        clang \
        libtool \
        zlib-dev zlib-static

ARG LOCAL
ARG CURL
ARG CURL_VERSION
ENV CURL_SRC=/usr/src/curl
RUN git clone --depth=1 --branch ${CURL_VERSION} https://github.com/curl/curl.git ${CURL_SRC}
WORKDIR ${CURL_SRC}

ADD ./artifacts/boringssl.tar.gz ${LOCAL}/

ENV CC="clang"
ENV LDFLAGS="-static"
ENV PKG_CONFIG="pkg-config --static"

RUN autoreconf -fi
RUN ./configure \
        --enable-shared=no \
        --with-ssl=${LOCAL} \
        --prefix=${CURL}
RUN make -j V=1 curl_LDFLAGS=-all-static
RUN make install


#------------------------------------------------------------------------------
#--- other nginx static build dependencies ---
FROM alpine as extra-static-libs

RUN apk add \
  libmaxminddb-dev libmaxminddb-static \
  protobuf-dev \
  yajl-dev

ARG LOCAL

WORKDIR ${LOCAL}

RUN cp -r /usr/include .

WORKDIR ${LOCAL}/lib

RUN cp /usr/lib/*.a .
RUN mv libyajl_s.a libyajl.a

RUN cp -r /usr/lib/pkgconfig .
RUN rm pkgconfig/zlib.pc
RUN for pattern in \
        "s|^prefix=.*|prefix=${LOCAL}|"  \
        's|^exec_prefix=.*|exec_prefix=\${prefix}|' \
        's|^libdir=.*|libdir=\${prefix}/lib|' \
        's|/usr/include|\${prefix}/include|'; do \
                for pc in ./pkgconfig/*.pc; do sed -e "$pattern" -i $pc; done \
    done


#------------------------------------------------------------------------------
#--- build hardened nginx with boringssl ---
FROM centos as nginx-builder

RUN groupadd --system --gid 101 www-data \
    && adduser --system -g www-data --no-create-home --home /nonexistent -c "www-data user" --shell /bin/false --uid 101 www-data

ARG CMAKEDIR=/opt/cmake
RUN mkdir -p ${CMAKEDIR}
RUN curl -sfL https://github.com/Kitware/CMake/releases/download/v3.20.0/cmake-3.20.0-linux-x86_64.tar.gz | tar --strip-components=1 -C ${CMAKEDIR} -xzf -

ARG PKG
ARG SRC

ENV PATH=$PATH:/usr/local/nginx/sbin:${CMAKEDIR}/bin

ARG LUA_PATH
ARG LUA_CPATH
ENV LUA_PATH=${LUA_PATH}
ENV LUA_CPATH=${LUA_CPATH}

ARG DEVTOOLSET=devtoolset-9

# install required packages to build
RUN yum install -y conntrack-tools findutils which centos-release-scl
RUN yum install -y ${DEVTOOLSET}-gcc ${DEVTOOLSET}-gcc-c++
RUN yum install -y \
  bash \
  make \
  automake \
  kernel-headers \
  perl-devel \
  mercurial \
  findutils \
  curl ca-certificates \
  patch \
  util-linux \
  wget \
  git flex bison doxygen libtool autoconf \
  python3 \
  bc \
  unzip \
  dos2unix \
  libyaml-devel \
  coreutils
RUN yum install -y \
  gd-devel \
  geoip-devel \
  pcre-devel \
  libaio-devel \
  libxml2-devel \
  libxslt-devel \
  zlib-devel
# RUN yum install -y \
#   libmaxminddb-devel \
#   protobuf-devel \
#   yajl-devel

RUN rm -rf /usr/local/*

COPY ./src/${PKG} /go/src/${PKG}

ARG LOCAL
ADD ./artifacts/boringssl.tar.gz ${LOCAL}/
COPY --from=extra-static-libs ${LOCAL}/ ${LOCAL}/

ARG CURL
COPY --from=curl-builder ${CURL} ${CURL}/

ENV CPATH="${LOCAL}/include:${CURL}/include"
ENV LIBRARY_PATH="${LOCAL}/lib:${CURL}/lib"
ENV PKG_CONFIG_PATH="${LOCAL}/lib/pkgconfig:${CURL}/lib/pkgconfig"
ENV LIBS="-pthread"

WORKDIR /tmp
RUN ln -s /go/src/${PKG}/images/nginx/rootfs/patches/ /patches
RUN cp /go/src/${PKG}/images/nginx/rootfs/build.sh .

RUN scl enable ${DEVTOOLSET} ./build.sh

RUN bash -eu -c ' \
  writeDirs=( \
    /var/lib/nginx/body \
    /var/lib/nginx/fastcgi \
    /var/lib/nginx/proxy \
    /var/lib/nginx/scgi \
    /var/lib/nginx/uwsgi \
  ); \
  for dir in "${writeDirs[@]}"; do \
    mkdir -p ${dir}; \
  done'


#------------------------------------------------------------------------------
#--- build hardened ingress-nginx with goboring ---
FROM go as ingress-nginx-builder
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

RUN bash -eu -c ' \
  writeDirs=( \
    /etc/ingress-controller \
    /etc/ingress-controller/ssl \
    /etc/ingress-controller/auth \
  ); \
  for dir in "${writeDirs[@]}"; do \
    mkdir -p ${dir}; \
  done'


#------------------------------------------------------------------------------
#--- create a runtime image ---
FROM ubi as build

WORKDIR /etc/nginx

RUN microdnf update -y && rm -rf /var/cache/yum
RUN microdnf install -y conntrack-tools findutils which gd geoip pcre libaio libxml2 libxslt zlib

RUN groupadd --system --gid 101 www-data \
    && adduser --system -g www-data --no-create-home --home /nonexistent -c "www-data user" --shell /bin/false --uid 101 www-data

ENV PATH=$PATH:/usr/local/nginx/sbin

ARG LUA_PATH
ARG LUA_CPATH
ENV LUA_PATH=${LUA_PATH}
ENV LUA_CPATH=${LUA_CPATH}

COPY --from=nginx-builder --chown=www-data:www-data /etc/nginx/ /etc/nginx/
#COPY --from=nginx-builder --chown=www-data:www-data /usr/local/nginx/ /usr/local/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /usr/local/ /usr/local/
COPY --from=nginx-builder --chown=www-data:www-data /opt/modsecurity/ /opt/modsecurity/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/audit/ /var/log/audit/
COPY --from=nginx-builder --chown=www-data:www-data /var/log/nginx/ /var/log/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /var/lib/nginx/ /var/lib/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/rootfs/etc/nginx/ /etc/nginx/
COPY --from=nginx-builder --chown=www-data:www-data /go/src/k8s.io/ingress-nginx/images/nginx/rootfs/etc/nginx/geoip/ /etc/nginx/geoip/

RUN mkdir -p /var/cache/nginx && \
    chown -R www-data:0 /var/cache/nginx && \
    chmod -R g=u /var/cache/nginx

COPY --from=ingress-nginx-builder --chown=www-data:www-data /usr/local/bin/ /
COPY --from=ingress-nginx-builder --chown=www-data:www-data /etc/ingress-controller/ /etc/ingress-controller/
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
