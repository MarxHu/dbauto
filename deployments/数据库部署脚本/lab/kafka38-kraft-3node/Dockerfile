FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Bake SOPS 预检依赖：Java>=17 + curl/tar/sha512sum/ss/pgrep/systemctl/hostname
# 预检只检查不现场补包，与 Redis 节点规范一致。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-17-jre-headless \
      curl \
      ca-certificates \
      tar \
      coreutils \
      iproute2 \
      iputils-ping \
      procps \
      hostname \
      bash \
      sudo \
 && rm -rf /var/lib/apt/lists/*

COPY systemctl-shim /usr/local/bin/systemctl
RUN chmod 0755 /usr/local/bin/systemctl \
 && ln -sfn /usr/local/bin/systemctl /usr/bin/systemctl \
 && mkdir -p /etc/systemd/system /opt/kafka /var/lib/kafka /var/log/kafka \
 && for c in java curl tar sha512sum ss pgrep systemctl hostname; do \
      command -v "$c" >/dev/null || { echo "MISSING $c"; exit 1; }; \
    done \
 && java -version 2>&1 | head -n1

# VM-like long-running node. SOPS 脚本由宿主机 docker exec 下发。
CMD ["sleep", "infinity"]
