# Build stage
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags "-s -w -X main.version=${VERSION}" -o server main.go

# Runtime stage — distroless-style Alpine
FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 65532 appuser \
    && mkdir -p /data && chown appuser:appuser /data
COPY --from=builder /app/server /usr/local/bin/server
USER 65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/server"]
