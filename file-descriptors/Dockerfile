FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY file-descriptors ./file-descriptors
RUN CGO_ENABLED=0 go build -p 1 -trimpath -ldflags="-s -w" -o /out/app ./file-descriptors

FROM alpine:3.21
RUN addgroup -S app && adduser -S -G app app
COPY --from=build /out/app /app
USER app:app
EXPOSE 8080
ENTRYPOINT ["/app"]