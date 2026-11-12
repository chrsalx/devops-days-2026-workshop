FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY database-connections ./database-connections
RUN CGO_ENABLED=0 go build -p 1 -trimpath -ldflags="-s -w" -o /out/app ./database-connections

FROM alpine:3.21
RUN addgroup -S app && adduser -S -G app app
COPY --from=build /out/app /app
USER app:app
EXPOSE 8080
ENTRYPOINT ["/app"]