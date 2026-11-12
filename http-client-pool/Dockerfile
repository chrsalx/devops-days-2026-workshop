FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY http-client-pool ./http-client-pool
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./http-client-pool

FROM alpine:3.21
RUN addgroup -S app && adduser -S -G app app
COPY --from=build /out/app /app
USER app:app
EXPOSE 8080
ENTRYPOINT ["/app"]