# Local development

## Make sure cross-platform builds are enabled

- Install QUEMO Emulation: `docker run --privileged --rm tonistiigi/binfmt --install all`
- Make sure a docker build builder is applied: `docker buildx create --use --name mybuilder && docker buildx inspect mybuilder --bootstrap`

## The easy way

Run `./project.sh` in the root of the project to build / debug / run the addon during development.

Here are the commands explained:

- `build` build the addon for the current architecture (see PLATFORM in the file) tag it as `dev` and push to GitHub Container Registry.

- `build-ha` Use the home-assistant builder to build all architechtures and push them to GitHub Container Registry with the tag `latest`.

- `run-hassos` build the addon for the current architecture (see PLATFORM in the file) tag it as `dev`, puish it to GitHub Container Registry, SSH login to home-assistant, and pull the image.

- `inspect` build the addon for the current architecture (see PLATFORM in the file) tag it as `dev`, and run it locally with an interactive shell (/bin/ash).

- `debug` build the addon for the current architecture (see PLATFORM in the file) tag it as `dev`, and run it locally with normal startup (not interactive).

## The manual way

To build the lastest version using local docker, switch to the folder where the `dockerfile` resides, and run:

```
docker build --platform linux/aarch64 --tag ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev .
```

The dockerfile already contains the default build architecture and the default base image:

```
ARG BUILD_FROM=ghcr.io/hassio-addons/base/aarch64:14.0.2
ARG BUILD_ARCH=aarch64
```

Hereafter, you can push the image to GitHub Container Registry using cmd of docker desktop for testing purposes.

## Build using Home Assistant Builder (https://github.com/home-assistant/builder)

To build the latest version using the HomeAssistant Addon Builder container, for `aarch64 architecture` for example, run:

```
docker run --rm --privileged -v ~/.docker:/root/.docker -v ~/hassos-addon-agent-memory-ledger/agent_memory_ledger:/data homeassistant/amd64-builder -v /var/run/docker.sock:/var/run/docker.sock:ro --target agent_memory_ledger --aarch64 -t /data
```

To use it with codenotary CAS signing:

```
docker run --rm --privileged --env CAS_API_KEY=$CAS_API_KEY -v ~/.docker:/root/.docker -v /var/run/docker.sock:/var/run/docker.sock:ro -v ~/hassos-addon-agent-memory-ledger/agent_memory_ledger:/data homeassistant/amd64-builder --target agent_memory_ledger --aarch64 -t /data
```

This will use the base images from the `build.yaml` file, and the architecture specified. Use `--all` instead of `--aarch64` to build all architectures within the `config.yaml`for example.

## Push latest DEV image to repository

docker image push ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev

## Pull latest DEV image into your raspoberry pi

SSH to a home assistant: `ssh -i hassos -l root -p 22222 10.50.1.104`
From a system SSH (port 22222):

```
docker image pull ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev
```

## Run the addon with an interactive shell

From a system SSH (port 22222), run the docker container with data attached:

```
docker run -it --entrypoint "/bin/sh" -v /mnt/data/supervisor/addons/data/local_agent_memory_ledger/:/data:rw  ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev
```

## For simple DEV inspection, run the container with a shell

```
docker run -it --entrypoint "/bin/sh" ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev
```

## OR attach to a running container

```
docker exec -it addon_local_agent_memory_ledger bash
```
