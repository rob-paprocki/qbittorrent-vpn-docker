# Docker Torrent Stack

This Docker Compose setup runs a complete torrenting stack with qBittorrent, Jackett, FlareSolverr, and File Browser, all secured behind a Gluetun VPN gateway.

It includes automatic port forwarding updates, container updates via Watchtower, and Discord notifications.

## Prerequisites
* Docker
* Docker Compose

## Setup

1.  Clone this repository:
    ```bash
    git clone <your_repo_url>
    ```
2.  Navigate into the project directory:
    ```bash
    cd <your_project_folder>
    ```
3.  Create your own environment file from the example:
    ```bash
    cp .env.example .env
    ```
4.  Edit the `.env` file and fill in all your personal information (VPN credentials, paths, Discord URLs, etc.).

5.  Launch the stack:
    ```bash
    docker-compose up -d
    ```
