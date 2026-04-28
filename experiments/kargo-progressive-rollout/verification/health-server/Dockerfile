FROM golang:1.22-alpine AS build
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 go build -o health-server .

FROM alpine:3.20
COPY --from=build /app/health-server /health-server
USER 65532:65532
ENTRYPOINT ["/health-server"]
