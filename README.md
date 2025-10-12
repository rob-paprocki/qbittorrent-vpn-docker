# Docker Torrent Stack

This Docker Compose setup runs a complete torrenting stack with qBittorrent, Jackett, FlareSolverr, and File Browser, all secured behind a Gluetun VPN gateway.

It includes automatic port forwarding updates, container updates via Watchtower, and Discord notifications.

## Prerequisites
* Docker
* Docker Compose

## Setup

1.  Create directory that stores your stacks
    ```bash
    mkdir -p /opt/stacks
    cd /opt/stacks
    ```
2.  Clone this repository:
    ```bash
    git clone https://github.com/rob-paprocki/docker-vpn-qbittorrent.git
    ```
3.  Navigate into the project directory:
    ```bash
    cd docker-vpn-qbittorrent
    ```
4.  Create your own environment file from the example:
    ```bash
    cp .env.example .env
    ```
5.  Edit the `.env` file and fill in all your personal information (VPN credentials, paths, Discord URLs, etc.).

6. Make the .sh executable
   ```bash
   chmod +x update-qbittorrent.sh
   ```

7.  Launch the stack:
    ```bash
    docker compose up -d
    ```
