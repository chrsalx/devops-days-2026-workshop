FROM golang:1.24-alpine AS build
WORKDIR /src
COPY labs/database-connections/go.mod labs/database-connections/go.sum ./
RUN go mod download
COPY labs/database-connections/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

FROM alpine:3.21
RUN addgroup -S app && adduser -S -G app app
COPY --from=build /out/app /app
USER app:app
EXPOSE 8080
ENTRYPOINT ["/app"]