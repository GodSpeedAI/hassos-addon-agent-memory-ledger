#!/bin/bash
set -e

PLATFORM="linux/arm64"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/godspeedai/agent-memory-ledger}"
DEPENDENCY_REPOSITORY="${DEPENDENCY_REPOSITORY:-ghcr.io/godspeedai/agent-memory-ledger/dependency}"

function printInColor() {
	# Set the color code based on the color name
	color=0
	case $2 in
	"red") color=31 ;;
	"green") color=32 ;;
	"yellow") color=33 ;;
	"blue") color=34 ;;
	"purple") color=35 ;;
	"cyan") color=36 ;;
	"white") color=37 ;;
	esac

	# Set the background color code based on the color name
	background=0
	case $3 in
	"red") background=41 ;;
	"green") background=42 ;;
	"yellow") background=43 ;;
	"blue") background=44 ;;
	"purple") background=45 ;;
	"cyan") background=46 ;;
	"white") background=47 ;;
	esac

	# Print the message in the given color, then reset the color
	echo -e "\e[${background}m\e[${color}m$1\e[0m"
}

function build_dependency() {
	local component=$1
	local version=$2

	printInColor "Building docker dependency ${component}" "green"

	docker buildx build \
		--push \
		--platform "linux/amd64,linux/arm64" \
		--cache-from "type=registry,ref=${DEPENDENCY_REPOSITORY}/${component}:cache" \
		--cache-to "type=registry,ref=${DEPENDENCY_REPOSITORY}/${component}:cache,mode=max" \
		--tag "${DEPENDENCY_REPOSITORY}/${component}:${version}" \
		--progress plain \
		--build-arg "VERSION=${version}" \
		--file "./agent_memory_ledger/docker-dependencies/${component}" \
		. &&
		printInColor "Done building docker image!" "green"
}

function build() {
	local output=$1

	printInColor "Building docker image.."

	# Build the image conform the instructions
	# Push the dev image to GitHub Container Registry
	# build the image
	docker buildx build \
		--platform ${PLATFORM} \
		--cache-from type=registry,ref="${IMAGE_REPOSITORY}:cache" \
		--tag "${IMAGE_REPOSITORY}/aarch64:dev" \
		--progress plain \
		--build-arg CACHE_BUST="$(date +%s)" \
		--output "${output}" \
		./agent_memory_ledger &&
		printInColor "Done building docker image!" "green"

	#Stop when an error occured
	# shellcheck disable=SC2181
	if [ $? -ne 0 ]; then
		printInColor "Error building docker image!" "red"
		exit 1
	fi
}

function run_hassos() {
	# Run the docker image on hassos
	printInColor "Pulling and restarting on HASSOS.. "

	# # Copy the docker image to hassos
	# printInColor "Pulling docker image on hassos.." "yellow"
	# # run the docker image pull command remote on Hassos
	ssh -i ~/.ssh/hassos -l root -p 22222 homeassistant "docker image pull ${IMAGE_REPOSITORY}/aarch64:dev \
        && ha addons stop  local_agent_memory_ledger  \
        && ha addons start local_agent_memory_ledger"
	printInColor "Done pulling docker image on hassos!" "green"
}

function run_local() {
	printInColor "Starting standalone docker image "

	# Run the docker image locally
	mkdir -p /tmp/timescale_data
	docker run --rm --name agent-memory-ledger --platform ${PLATFORM} -v /tmp/timescale_data:/data -p 5432:5432 "${IMAGE_REPOSITORY}/aarch64:dev"
}

function release() {
	local tag=$1
	printInColor "Releasing docker images: retagging from [latest] with tag ${tag}.."

	#Get all platforms from /agent_memory_ledger/config.yaml
	platforms=$(yq -r '.arch[]' ./agent_memory_ledger/config.yaml)

	#And loop through them
	for platform in $platforms; do
		printInColor "Releasing platform ${platform} with tag ${tag}.."

		docker tag "${IMAGE_REPOSITORY}/${platform}:latest" "${IMAGE_REPOSITORY}/${platform}:${tag}"
		docker push "${IMAGE_REPOSITORY}/${platform}:${tag}"
	done
}

function inspect() {
	local tag=$1
	printInColor "Starting standalone docker image shell"

	# Run the docker image locally
	mkdir -p /tmp/timescale_data
	docker run --entrypoint "/bin/ash" -it --rm --name agent-memory-ledger --platform ${PLATFORM} -v /tmp/timescale_data:/data -p 5432:5432 "${IMAGE_REPOSITORY}/aarch64:dev"
}

function build_all() {
	local tag=$1
	printInColor "Building all platforms for Home Assistant with tag ${tag}"

	# Get all platforms from /agent_memory_ledger/config.yaml
	platforms=$(yq -r '.arch[]' ./agent_memory_ledger/config.yaml)

	# And loop through them
	for platform in $platforms; do

		# Get the value from agent_memory_ledger/build.yaml by looking it up in the build_from dictionary, whereby the key value of the list is the platform.
		build_from=$(yq -r ".build_from.${platform}" ./agent_memory_ledger/build.yaml)

		# Convert the platform to the correct format
		case $platform in
		"aarch64") docker_platform="linux/arm64" ;;
		"amd64") docker_platform="linux/amd64" ;;
		esac

		printInColor "Building platform ${platform} (${docker_platform}) for Home Assistant with tag ${tag}" "green"

		docker buildx build \
			--platform "${docker_platform}" \
			--cache-from type=registry,ref="${IMAGE_REPOSITORY}:cache" \
			--cache-to type=registry,ref="${IMAGE_REPOSITORY}:cache,mode=max" \
			--tag "${IMAGE_REPOSITORY}/${platform}:${tag}" \
			--build-arg "BUILD_FROM=${build_from}" \
			--build-arg "BUILD_ARCH=${platform}" \
			--build-arg "BUILD_VERSION=${tag}" \
			--file ./agent_memory_ledger/Dockerfile \
			--output type=registry,push=true \
			./agent_memory_ledger &&
			printInColor "Done building docker image!" "green"
	done
}

# Builds a dev tagged image locally
if [ "$1" == "build" ]; then
	build "type=docker"
	exit 0

# Builds a dev tagged image, and pushes it to the registry
elif [ "$1" == "build-push" ]; then
	build "type=registry,push=true"
	exit 0

# Builds all dependencies or a specific one, an pushes it to the registry
elif [ "$1" == "build-dependencies" ]; then

	# If the second argument is not set, then build all dependencies
	# Otherwise, only build the given dependency
	if [ -z "$2" ]; then
		printInColor "Building all dependencies.."

		build_dependency timescaledb-tools "latest"
		build_dependency pgagent-pg16 "pgagent-4.2.3"
		build_dependency pgagent-pg17 "pgagent-4.2.3"
		build_dependency timescaledb-toolkit-pg16 "1.22.0"
		build_dependency timescaledb-toolkit-pg17 "1.22.0"
		build_dependency postgis-pg16 "3.6.3"
		build_dependency postgis-pg17 "3.6.3"
		build_dependency postgresql-extension-system-stat-pg16 "4.1"
		build_dependency postgresql-extension-system-stat-pg17 "4.1"
		build_dependency ruvector-pg17 "2.0.5"
	else
		printInColor "Building dependency $2.."
		build_dependency "$2" "$3"
	fi
	exit 0

# Build all architectures for Home Assistant with the latest tag and pushes it to the registry
elif [ "$1" == "build-all" ]; then
	build_all latest
	exit 0

# Builds a dev tagged image, pushes it tourgh the registy and restarts the addon on Hassos
elif [ "$1" == "run-hassos" ]; then
	build "type=registry,push=true"
	run_hassos
	exit 0

# Builds and runs a dev tagged image locally
elif [ "$1" == "debug" ]; then
	build type=docker
	run_local
	exit 0

# Runs a shell in the dev tagged image locally
elif [ "$1" == "inspect" ]; then
	# build type=docker
	inspect "$2"
	exit 0

# Retags the output images of build_all (latest) to the given tag and pushes them to the registry
elif [ "$1" == "release" ]; then
	release "$2"
	exit 0

else
	printInColor "Unknown command!" "red"
	exit 1

fi
