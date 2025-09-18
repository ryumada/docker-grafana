# Mimir Configuration Update Guide

This guide explains how to update the Mimir configuration in your Docker Swarm environment.

## 1. Update `config.yaml`

Modify the Mimir configuration file located at `mimir/config.yaml` with your desired changes.

## 2. Re-run `setup.sh`

Execute the `setup.sh` script from the project root directory. This script will re-render the `mimir/config.yaml` file (and other configuration files) based on your `.env` settings and the `config.yaml.example` template. It will also create a backup of your existing `mimir/config.yaml` before overwriting it.

```bash
./setup.sh
```

## 3. Update the Docker Swarm Config

After `setup.sh` has run, the `mimir/config.yaml` file will be updated. You then need to update the Docker Swarm config that Mimir services are using.

The Docker Swarm config name for Mimir is `mimir-config`.

First, remove the old config:
```bash
docker config rm mimir-config
```

Then, create a new config from the updated `mimir/config.yaml`:
```bash
docker config create mimir-config ./mimir/config.yaml
```

## 4. Update the Mimir Service

Finally, update the Mimir Docker service to use the new configuration. This will trigger a rolling update of your Mimir services.

```bash
docker service update --config-add source=mimir-config,target=/etc/mimir/mimir.yaml mimir_mimir
```

**Note:** The service name `mimir_mimir` is an example. Please verify your actual Mimir service name using `docker service ls`.
