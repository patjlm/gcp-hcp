FROM alpine:3.20
RUN apk add --no-cache bash
COPY check.sh /check.sh
RUN chmod +x /check.sh
ENTRYPOINT ["/check.sh"]
