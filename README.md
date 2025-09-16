# Grafana Observability Stack Deployment Guide

This repository ships Swarm-ready Docker Compose specs for a distributed Grafana observability stack. Traefik provides reverse-proxy and automated TLS, while Loki, Mimir, Alertmanager, and Grafana deliver log, metric, and alerting workflows. Grafana Alloy acts as the single data-collection agent on every node. Named volumes and externalized object storage keep data durable across restarts.

---

## Final Architecture

* **VPS 1 (Proxy / Manager):** Runs the Traefik reverse proxy and hosts Grafana.
* **VPS 2 (Logs):** Runs Grafana Loki for log ingestion and query.
* **VPS 3 (Metrics & Alerts):** Runs Grafana Mimir and Alertmanager.
* **VPS 4 (Agents):** Runs Grafana Alloy to collect logs and metrics (deploy as many agent nodes as you need).

* **(Optional) Additional VPSs:** Join more worker nodes to the swarm and deploy additional Alloy agents for wider coverage.

*Note: You can consolidate services on fewer VPSs, but the instructions assume a fully distributed layout for clarity.*

---

## Prerequisites

1. **Multiple VPSs:** Each running a modern Linux distribution (Ubuntu 22.04 or later recommended).
2. **Docker & Docker Swarm:** Installed on all VPSs. Docker Compose v2 is required (`docker compose` CLI).
3. **DNS A Record:** Point a domain such as `grafana.example.com` to the public IP of your proxy node (VPS 1) so Traefik can request certificates.
4. **Object Storage:** Google Cloud Storage buckets for Loki and Mimir data (update bucket names in their configs).
5. **This Repository:** Cloned onto each server that will run a service.

---

## Step 1: Prepare Secrets and Configuration

On the manager node (VPS 1), copy `.env.example` to `.env` and provide the required secrets:

* `LOKI_GCS_SERVICE_ACCOUNT_JSON_B64` – base64-encoded Loki service account JSON (use `loki/gcs-service-account.json.example` as a reference).
* `MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64` – base64-encoded Mimir service account JSON (see `mimir/gcs-service-account.json.example`).
* `ALERTMANAGER_GOOGLE_CHAT_WEBHOOK_URL` – Google Chat webhook URL (see `alertmanager/google-chat-webhook.url.example`).

Run `./install.sh` to materialize these secrets and render the service `docker-compose.yml` files from their `.example` templates. Review and adjust the configuration files (`loki/config.yaml`, `mimir/config.yaml`, `grafana/provisioning/datasources/datasources.yaml`, `alloy/config.alloy`) to match your bucket names, domains, and alerting requirements. Do **not** commit credentials to version control.

---

## Step 2: Secure the Swarm with a Firewall (Recommended)

Restrict swarm-management ports so only your nodes can reach them.

Required open ports between every swarm node:
* **TCP 2377** – cluster management traffic.
* **TCP/UDP 7946** – node gossip.
* **UDP 4789** – overlay network data plane.

Create the optional UFW profile via `./scripts/create_docker_swarm_ufw_app_profile.sh` if you are on Ubuntu, then allow traffic from each peer:

```bash
sudo ufw allow from IP_OF_NODE to any app "Docker Swarm"
```

Or manually add rules (repeat on every VPS, replacing placeholder IPs):

```bash
sudo ufw allow from IP_OF_NODE to any port 2377 proto tcp
sudo ufw allow from IP_OF_NODE to any port 7946
sudo ufw allow from IP_OF_NODE to any port 4789 proto udp
sudo ufw reload
```

Validate connectivity from peer nodes:

```bash
nc -vz MANAGER_IP 2377
nc -vz PEER_IP 7946
nc -vzu PEER_IP 7946
nc -vzu PEER_IP 4789
```

---

## Step 3: Initialize the Docker Swarm

1. SSH into **VPS 1** (manager) and initialize the swarm:
   ```bash
   docker swarm init --advertise-addr <MANAGER_PRIVATE_IP> --data-path-addr <MANAGER_PRIVATE_IP>
   ```
2. Copy the `docker swarm join` command printed by Docker.
3. SSH into every other VPS (Loki, Mimir/Alertmanager, Alloy nodes) and run the join command.
4. Label nodes so stacks land on the intended hosts:
   ```bash
   docker node update --label-add role.proxy=true proxy-node-name
   docker node update --label-add role.grafana=true grafana-node-name
   docker node update --label-add role.loki=true loki-node-name
   docker node update --label-add role.mimir=true mimir-node-name
   docker node update --label-add role.alertmanager=true alertmanager-node-name
   docker node update --label-add role.alloy=true alloy-node-name
   ```

---

## Step 4: Create the Encrypted Overlay Network

From the manager node, create the shared `grafana` overlay network once. Confirm the MTU of your underlying network (`ip a`) and choose the appropriate command:

```bash
# Default: encrypted overlay with MTU 1500
docker network create --driver overlay --opt encrypted --attachable grafana

# If using WireGuard / reduced MTU (example 1420)
docker network create \
  --driver overlay \
  --opt encrypted \
  --attachable \
  --opt com.docker.network.driver.mtu=1420 \
  grafana

# Without encryption when ESP is unavailable but WireGuard is in place
docker network create \
  --driver overlay \
  --attachable \
  --opt com.docker.network.driver.mtu=1420 \
  grafana
```

---

## Step 5: Deploy the Services

Run all stack deployments from the manager node at the repository root. The examples below use the stack name `observability`.

```bash
cd /path/to/docker-loki

docker stack deploy -c traefik/docker-compose.yml observability
docker stack deploy -c grafana/docker-compose.yml observability
docker stack deploy -c loki/docker-compose.yml observability
docker stack deploy -c mimir/docker-compose.yml observability
docker stack deploy -c alertmanager/docker-compose.yml observability
docker stack deploy -c alloy/docker-compose.yml observability
```
All services share the external `grafana` network so Traefik can route traffic and the back-end systems can communicate. Re-run `./install.sh` whenever you modify `.env` to refresh the rendered compose files before deploying.

---

## Step 6: Verify the Deployment

1. **Check service health:**
   ```bash
   docker service ls
   ```
   Ensure each service reports the desired replica count (e.g., `1/1`).

2. **Inspect placement:**
   ```bash
   docker service ps observability_grafana
   ```
   Confirm services run on the nodes you labeled.

3. **Validate Grafana:** Visit `https://grafana.example.com` (replace with your domain). Traefik may take a minute to issue certificates.

4. **Smoke-test ingestion:** Use Grafana’s Explore view to query `Loki` and `Mimir` datasources for sample logs and metrics.

---

## Troubleshooting & Advanced Setup

### context deadline exceeded when deploying

This usually indicates blocked swarm ports. Double-check cloud-provider firewalls and host-based rules. When network restrictions cannot be relaxed, tunnel swarm traffic through WireGuard using the private IPs in your `docker swarm init` and `docker swarm join` commands.

### WireGuard overlay transport

Follow these condensed steps on every VPS if you elect to run the swarm over WireGuard:

1. Install WireGuard:
   ```bash
   sudo apt update && sudo apt install wireguard -y
   ```
2. Generate keys on each node (`/etc/wireguard/private.key` and `public.key`).
3. Configure `/etc/wireguard/wg0.conf` with unique `/24` addresses (e.g., `10.10.0.0/24`). The manager lists every peer; workers reference the manager as their peer.
4. Enable IP forwarding on the manager (`net.ipv4.ip_forward=1`) and reload sysctl.
5. Allow UDP 51820 on all firewalls, bring the interface up, and enable at boot:
   ```bash
   sudo ufw allow 51820/udp
   sudo wg-quick up wg0
   sudo systemctl enable wg-quick@wg0
   ```
6. Permit swarm ports over the WireGuard subnet and re-run `docker swarm init --advertise-addr <WG_IP>` and the join commands.

### Scaling Alloy agents

Alloy is deployed with `mode: global` by default, so every labeled node runs a single agent. To limit Alloy to specific nodes, adjust the deploy section with placement constraints or remove the global mode and manually scale:

```bash
docker service scale observability_alloy=3
```

### Updating configurations

After editing a configuration or secret, re-run the corresponding `docker stack deploy -c ... observability` command. Swarm performs rolling updates and mounts the refreshed config/secret automatically.

---

## Persisting Binaries and Artifacts

* Loki and Mimir rely on GCS buckets for long-term storage. Ensure lifecycle policies, retention, and IAM permissions meet your compliance requirements.
* Grafana stores dashboards and state in the `grafana-data` volume. Create regular backups by snapshotting the Swarm volume driver storage or copying `/var/lib/docker/volumes` from the host.

---

## Directory Reference

* `traefik/` – reverse proxy configuration and Let's Encrypt storage.
* `grafana/` – Grafana deployment and datasource provisioning.
* `loki/` – Loki service definition, config, and credentials template.
* `mimir/` – Mimir service definition, config, and credentials template.
* `alertmanager/` – Alertmanager deployment and Google Chat receiver config.
* `alloy/` – Grafana Alloy agent configuration for logs and host metrics.
* `.env.example` – Template of required secret variables and compose settings.
* `install.sh` – Helper script to materialize secrets from `.env` and render compose files.
* `*/docker-compose.yml.example` – Templates consumed by `install.sh` to produce deployable manifests.

---

Copyright © 2025. Released under the MIT License.
