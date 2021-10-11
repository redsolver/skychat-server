FROM debian:latest

RUN apt-get update && apt-get install ca-certificates -y

ADD web/main.exe /app/bin/server

EXPOSE 8080

ENTRYPOINT ["/app/bin/server"]
