FROM alpine:3.24
RUN apk add --no-cache postgresql16-client openssh-client rsync bash gzip
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
