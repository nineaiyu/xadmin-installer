FROM registry.cn-beijing.aliyuncs.com/nineaiyu/nginx:1.31.5-alpine

ARG ALPINE_MIRROR=mirrors.tuna.tsinghua.edu.cn

# Install APK dependencies (Alpine)
ARG DEPENDENCIES="                    \
        bash                          \
        curl                          \
        socat                         \
        coreutils                     \
        openssl                       \
        ca-certificates"

RUN set -ex \
    && sed -i "s@dl-cdn.alpinelinux.org@${ALPINE_MIRROR}@g" /etc/apk/repositories \
    && apk add --no-cache ${DEPENDENCIES}


RUN mkdir -p /var/www/acme-challenge

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/xadmin-api-conf /etc/nginx/conf.d/xadmin-api-conf

# vendored acme.sh（第三方脚本）随镜像内置：entrypoint 安装到 /root/.acme.sh，
# 无需宿主机挂载（迁移前镜像内不含 acme.sh，依赖运行期挂载仓库目录）
COPY acme.sh/ /web/acme.sh/

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 80 443

ENTRYPOINT ["/bin/bash", "entrypoint.sh"]

STOPSIGNAL SIGQUIT
