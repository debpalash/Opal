FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
COPY opal_*_compat_amd64.deb /tmp/opal.deb
RUN apt-get update && apt-get install -y /tmp/opal.deb xvfb xauth \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/install.sh /tmp/install.sh
COPY packaging/linux-compat/smoke.py /tmp/smoke.py
CMD ["python3", "/tmp/smoke.py"]
