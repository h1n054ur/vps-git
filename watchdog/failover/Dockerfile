FROM python:3.14-alpine
RUN apk add --no-cache openssh-client ansible-core curl bash && \
    pip install --no-cache-dir requests
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY failover.py /failover.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
