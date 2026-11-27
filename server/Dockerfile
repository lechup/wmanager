# The image of wmanager-server (docs/server.md). Built from the repository's top:
#   docker build -f server/Dockerfile -t wmanager-server .
# The program runs as an unprivileged user in a distroless image (no shell, no package manager).
FROM golang:1.27.4-bookworm@sha256:ce59b41415e2524ae99926fe1f37ce48ba8c194dcbd2a56a65436cdcefa2bd34 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY verify/ verify/
COPY internal/ internal/
COPY server/ server/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/wmanager-server ./server/cmd/wmanager-server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/wmanager-server /usr/local/bin/wmanager-server
USER nonroot:nonroot
ENV WMANAGER_LISTEN=:8080
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s CMD ["/usr/local/bin/wmanager-server", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/wmanager-server"]
CMD ["serve"]
