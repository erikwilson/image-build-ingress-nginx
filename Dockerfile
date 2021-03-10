ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.15.8b5

FROM ${UBI_IMAGE} as ubi

#--- build hardened nginx with boringssl ---
#--- adapted from https://github.com/nginx-modules/docker-nginx-boringssl ---
FROM ${GO_IMAGE} as nginx-builder

RUN apk add \
        build-base \
        brotli-static \
        bzip2-static \
        cmake \
        freetype-static \
        gd-dev \
        geoip-dev \
        gnupg \
        libjpeg-turbo-static \
        libpng-static \
        libwebp-static \
        libxslt-dev \
        linux-headers \
        pcre-dev \
        zlib-dev \
        zlib-static

WORKDIR /usr/src

RUN git clone --depth=1 --recurse-submodules https://github.com/google/ngx_brotli
RUN git clone --depth=1 https://github.com/openresty/headers-more-nginx-module ngx_headers_more
RUN git clone --depth=1 https://boringssl.googlesource.com/boringssl

RUN sed -i 's@out \([>=]\) TLS1_2_VERSION@out \1 TLS1_3_VERSION@' ./boringssl/ssl/ssl_lib.cc
RUN sed -i 's@ssl->version[ ]*=[ ]*TLS1_2_VERSION@ssl->version = TLS1_3_VERSION@' ./boringssl/ssl/s3_lib.cc
RUN sed -i 's@(SSL3_VERSION, TLS1_2_VERSION@(SSL3_VERSION, TLS1_3_VERSION@' ./boringssl/ssl/ssl_test.cc
RUN sed -i 's@\$shaext[ ]*=[ ]*0;@\$shaext = 1;@' ./boringssl/crypto/*/asm/*.pl
RUN sed -i 's@\$avx[ ]*=[ ]*[0|1];@\$avx = 2;@' ./boringssl/crypto/*/asm/*.pl
RUN sed -i 's@\$addx[ ]*=[ ]*0;@\$addx = 1;@' ./boringssl/crypto/*/asm/*.pl

RUN mkdir -p ./boringssl/build ./boringssl/.openssl/lib ./boringssl/.openssl/include \
    && ln -sf /usr/src/boringssl/include/openssl ./boringssl/.openssl/include/openssl \
    && touch ./boringssl/.openssl/include/openssl/ssl.h

RUN cmake -B./boringssl/build -H./boringssl -DCMAKE_BUILD_TYPE=RelWithDebInfo
RUN make -C./boringssl/build -j$(getconf _NPROCESSORS_ONLN)
RUN cp ./boringssl/build/crypto/libcrypto.a ./boringssl/build/ssl/libssl.a ./boringssl/.openssl/lib/

ARG NGINX_VERSION=1.18.0
RUN curl -fSL https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz
RUN curl -fSL https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz.asc -o nginx.tar.gz.asc

ENV GPG_KEYS=B0F4253373F8F6F510D42178520A9993A1C052F8
RUN export GNUPGHOME="$(mktemp -d)" \
    && found=''; \
    for server in \
        ha.pool.sks-keyservers.net \
        hkp://keyserver.ubuntu.com:80 \
        hkp://p80.pool.sks-keyservers.net:80 \
        pgp.mit.edu \
    ; do \
        echo "Fetching GPG key $GPG_KEYS from $server"; \
        gpg --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$GPG_KEYS" && found=yes && break; \
    done; \
    test -z "$found" && echo >&2 "error: failed to fetch GPG key $GPG_KEYS" && exit 1; \
    gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz

RUN tar -xzf nginx.tar.gz
WORKDIR /usr/src/nginx-$NGINX_VERSION
COPY patches/ /usr/src/patches/
RUN for p in $(ls /usr/src/patches/*); do patch -p1 < $p; done

ARG NGINX_CONFIG="\
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-http_xslt_module \
        --with-http_image_filter_module \
        --with-http_geoip_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module \
        --with-http_slice_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-compat \
        --with-file-aio \
        --with-http_v2_module \
        --with-cc-opt='-no-pie -static -I/usr/src/boringssl/.openssl/include' \
        --with-ld-opt='-no-pie -static -L/usr/src/boringssl/.openssl/lib' \
        --add-module=/usr/src/ngx_headers_more \
        --add-module=/usr/src/ngx_brotli \
"

RUN eval "./configure $NGINX_CONFIG --with-debug"
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN mv objs/nginx objs/nginx-debug

RUN eval "./configure $NGINX_CONFIG"
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN make install

RUN mkdir /etc/nginx/conf.d/ \
    && mkdir -p /usr/share/nginx/html/ \
    && install -m644 html/index.html /usr/share/nginx/html/ \
    && install -m644 html/50x.html /usr/share/nginx/html/ \
    && install -m755 objs/nginx-debug /usr/sbin/nginx-debug \
    && strip /usr/sbin/nginx*

COPY conf/nginx.conf /etc/nginx/nginx.conf
# COPY conf/nginx.vh.no-default.conf /etc/nginx/conf.d/default.conf

RUN addgroup -S --gid 1001 nginx
RUN adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx --uid 1001 nginx

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /var/log/nginx/access.log
RUN ln -sf /dev/stderr /var/log/nginx/error.log


#--- build hardened nginx with goboring ---
FROM ${GO_IMAGE} as ingress-nginx-builder
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


#--- create a runtime image ---
FROM ubi

RUN microdnf update -y && rm -rf /var/cache/yum
RUN microdnf install -y conntrack-tools findutils which

RUN groupadd --system --gid 1001 nginx \
    && adduser --system -g nginx --no-create-home --home /nonexistent -c "nginx user" --shell /bin/false --uid 1001 nginx

COPY --from=nginx-builder /usr/sbin/nginx* /usr/sbin/
COPY --from=nginx-builder /etc/nginx/ /etc/nginx/
COPY --from=nginx-builder /usr/share/nginx/ /usr/share/nginx/
COPY --from=nginx-builder /var/log/nginx/ /var/log/nginx/

RUN mkdir -p /var/cache/nginx && \
    chown -R nginx:0 /var/log/nginx/ /var/cache/nginx /usr/share/nginx && \
    chmod -R g=u /var/log/nginx/ /var/cache/nginx /usr/share/nginx

COPY --from=ingress-nginx-builder /usr/local/bin/ /usr/local/bin/

RUN nginx-ingress-controller --version
