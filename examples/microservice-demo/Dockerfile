# Build stage
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o microservice-demo main.go

# Runtime stage
FROM alpine:3.18
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 appuser
COPY --from=builder /app/microservice-demo /usr/local/bin/
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O- http://localhost:8080/health || exit 1
CMD ["/usr/local/bin/microservice-demo"]
