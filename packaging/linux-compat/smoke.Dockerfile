ARG BASE_IMAGE=ubuntu:20.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
COPY opal_*_compat_amd64.deb /tmp/opal.deb
RUN apt-get update && apt-get install -y /tmp/opal.deb xvfb xauth \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/install.sh /tmp/install.sh
COPY packaging/linux-compat/smoke.py /tmp/smoke.py
COPY packaging/linux-compat/elf.py /tmp/elf.py
CMD ["python3", "/tmp/smoke.py"]
