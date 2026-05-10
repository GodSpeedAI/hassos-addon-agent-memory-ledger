ARG BUILD_FROM=ghcr.io/hassio-addons/base/aarch64:20.1.1
ARG BUILD_ARCH=aarch64

ARG ALPINE_VERSION=3.23

# Define the versions for all components of the addon
# These images are all prebuild, otherwise building the docker images takes waaaay to long
# Where possible, we just take the latest version from the Alpine repository, so it's
# possible we won't mention the latest version here.
FROM timescale/timescaledb:2.26.4-pg16                                          AS timescale-pg16
FROM timescale/timescaledb:2.26.4-pg17                                          AS timescale-pg17

# hadolint ignore=DL3007
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/timescaledb-tools:latest                    AS timescaledb-tools
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/pgagent-pg16:pgagent-4.2.3                  AS pgagent-pg16
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/pgagent-pg17:pgagent-4.2.3                  AS pgagent-pg17
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/postgis-pg16:3.6.3                          AS postgis-pg16
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/postgis-pg17:3.6.3                          AS postgis-pg17
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/timescaledb-toolkit-pg16:1.22.0             AS timescaledb-toolkit-pg16
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/timescaledb-toolkit-pg17:1.22.0             AS timescaledb-toolkit-pg17
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/postgresql-extension-system-stat-pg16:4.1   AS system-stat-pg16
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/postgresql-extension-system-stat-pg17:4.1   AS system-stat-pg17
FROM ghcr.io/godspeedai/agent-memory-ledger/dependency/ruvector-pg17:2.0.5                         AS ruvector-pg17


###########################################
# Define base Image
###########################################
# hadolint ignore=DL3006
FROM $BUILD_FROM AS addon
ARG BUILD_ARCH
ARG TARGETARCH=${BUILD_ARCH}
ARG TARGETVARIANT

# Add some handy tools
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk update \
    && apk add ca-certificates \
    && apk add \
        wget \
        rsync \
        nano

# Upgrade SSL libraries
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add --upgrade libssl3 libcrypto3

###########################################
# Install all sub-components
###########################################

# -----------------------------------------
# PostgreSql 16 (old)
# -----------------------------------------
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add \
        postgresql16-jit \
        postgresql16 \
        postgresql16-dev \
        postgresql16-contrib-jit \
        postgresql16-contrib

# -----------------------------------------
# PostgreSql 17 (new)
# Note: PostgreSQL 17 is not yet in Alpine 3.23, install from edge
# -----------------------------------------
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        postgresql17-jit \
        postgresql17 \
        postgresql17-dev \
        postgresql17-contrib-jit \
        postgresql17-contrib

# Set default postgresql version to 17
RUN rm /usr/libexec/postgresql \
    && ln -s /usr/libexec/postgresql17 /usr/libexec/postgresql \
    && rm /usr/share/postgresql \
    && ln -s /usr/share/postgresql17 /usr/share/postgresql

# Create it's run directory
RUN mkdir -p /run/postgresql \
	&& chown -R postgres:postgres /run/postgresql \
    && mkdir -p /run/postgresql/extensions \
	&& chown -R postgres:postgres /run/postgresql/extensions

# -----------------------------------------
# Extension Postgis pg-16 (old)
# -----------------------------------------

# Postgis + Postgis-Raster
COPY --from=postgis-pg16 --link /usr/local/lib/postgresql/postgis* /usr/lib/postgresql16/

COPY --from=postgis-pg16 --link /usr/local/lib/postgresql/bitcode/postgis-3/* /usr/lib/postgresql16/bitcode/postgis-3/
COPY --from=postgis-pg16 --link /usr/local/lib/postgresql/bitcode/postgis_raster-3/* /usr/lib/postgresql16/bitcode/postgis_raster-3/

COPY --from=postgis-pg16 --link /usr/local/share/postgresql/contrib/postgis* /usr/share/postgresql16/contrib/
COPY --from=postgis-pg16 --link /usr/local/share/postgresql/extension/postgis* /usr/share/postgresql16/extension/

# -----------------------------------------
# Extension Postgis pg-17 (new)
# -----------------------------------------
#Add required packages for runtime (see postgis dependencies)
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add  \
        openexr \
        poppler \
        gdal \
        geos \
        json-c \
        libgcc \
        libpq \
        libstdc++ \
        libxml2 \
        musl \
        pcre \
        perl \
        proj \
        protobuf-c

# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/community --allow-untrusted \
        #postgis=3.5.0-r5 \
        gdal-driver-postgisraster \
    && \
    apk add --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/main \
        libturbojpeg

# Postgis + Postgis-Raster
COPY --from=postgis-pg17 --link /usr/local/lib/postgresql/postgis* /usr/lib/postgresql17/

COPY --from=postgis-pg17 --link /usr/local/lib/postgresql/bitcode/postgis-3/* /usr/lib/postgresql17/bitcode/postgis-3/
COPY --from=postgis-pg17 --link /usr/local/lib/postgresql/bitcode/postgis_raster-3/* /usr/lib/postgresql17/bitcode/postgis_raster-3/

COPY --from=postgis-pg17 --link /usr/local/share/postgresql/contrib/postgis* /usr/share/postgresql17/contrib/
COPY --from=postgis-pg17 --link /usr/local/share/postgresql/extension/postgis* /usr/share/postgresql17/extension/

# -----------------------------------------
# Extension Timescale pg-16 (old)
# -----------------------------------------
# Copy the new timescale version to the old postgresql version
COPY --from=timescale-pg16 --link /usr/local/lib/postgresql/timescaledb*.so /usr/lib/postgresql16/
COPY --from=timescale-pg16 --link /usr/local/share/postgresql/extension/timescaledb* /usr/share/postgresql16/extension/

# -----------------------------------------
# Extension Timescale pg-17 (new)
# -----------------------------------------
# Copy the new timescale version to the new postgresql version
COPY --from=timescale-pg17 --link /usr/local/lib/postgresql/timescaledb*.so /usr/lib/postgresql17/
COPY --from=timescale-pg17 --link /usr/local/share/postgresql/extension/timescaledb* /usr/share/postgresql17/extension/

# --------------------------------------------
# Extension pgAgent pg-17 (new)
# --------------------------------------------
# Copy the new timescale version to the new postgresql version
COPY --from=pgagent-pg17 --link /usr/local/lib/postgresql/pgagent*.so /usr/lib/postgresql17/
COPY --from=pgagent-pg17 --link /usr/local/share/postgresql/extension/pgagent* /usr/share/postgresql17/extension/

COPY --from=pgagent-pg17 --link /usr/local/share/pgagent.sql /usr/local/share/
COPY --from=pgagent-pg17 --link /usr/local/bin/pgagent /usr/local/bin/

# Add compatibility libraries
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add \
        boost-libs

# --------------------------------------
# Extension Timescaledb-Toolkit pg16 (old)
# --------------------------------------
# Copy new timescaledb-toolkit to new postgresql version
COPY --from=timescaledb-toolkit-pg16 --link /usr/local/lib/postgresql/timescaledb_toolkit* /usr/lib/postgresql16/
COPY --from=timescaledb-toolkit-pg16 --link /usr/local/share/postgresql/extension/timescaledb_toolkit* /usr/share/postgresql16/extension/

# --------------------------------------
# Extension Timescaledb-Toolkit pg17 (new)
# --------------------------------------
# Copy new timescaledb-toolkit to new postgresql version
COPY --from=timescaledb-toolkit-pg17 --link /usr/local/lib/postgresql/timescaledb_toolkit* /usr/lib/postgresql17/
COPY --from=timescaledb-toolkit-pg17 --link /usr/local/share/postgresql/extension/timescaledb_toolkit* /usr/share/postgresql17/extension/

# Add compatibility libraries for timescaledb toolkit
# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-${TARGETARCH}-${TARGETVARIANT},sharing=locked,target=/var/cache/apk \
    set -ex \
    && apk add \
        gcompat \
        clang19-libclang

# --------------------------------------------
# Extension System-Stat pg-16 (old)
# --------------------------------------------
COPY --from=system-stat-pg16 --link /usr/local/lib/postgresql/system_stats*.so /usr/lib/postgresql16/
COPY --from=system-stat-pg16 --link /usr/local/share/postgresql/extension/system_stats* /usr/share/postgresql16/extension/

# --------------------------------------------
# Extension System-Stat pg-17 (new)
# --------------------------------------------
COPY --from=system-stat-pg17 --link /usr/local/lib/postgresql/system_stats*.so /usr/lib/postgresql17/
COPY --from=system-stat-pg17 --link /usr/local/share/postgresql/extension/system_stats* /usr/share/postgresql17/extension/

# --------------------------------------------
# Extension RuVector pg-17 (new)
# Vector search extension
# --------------------------------------------
COPY --from=ruvector-pg17 --link /usr/local/lib/postgresql/ruvector*.so /usr/lib/postgresql17/
COPY --from=ruvector-pg17 --link /usr/local/share/postgresql/extension/ruvector* /usr/share/postgresql17/extension/

# --------------------------------------
# Timescaledb Tools (always latest)
# --------------------------------------
# Copy timescaledb-tools
COPY --from=timescaledb-tools /go/bin/* /usr/local/bin/

###########################################
# Finalize Image
###########################################

# Make sure that S6 is not so hard on our service startup/shutdown
ENV \
    S6_SERVICES_GRACETIME=50000 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0

ARG CACHE_BUST

# Timestamp the build
RUN date +%Y%m%d%H%M%S > /build-timestamp

# Copy root fs files
# hadolint ignore=DL3021
COPY --link rootfs /rootfs
RUN rsync -LKavz /rootfs/ / && rm -rf /rootfs

# Make backup, restore, and agent_memory scripts executable
RUN chmod +x /usr/share/agent_memory_ledger/backup_pre.sh \
    && chmod +x /usr/share/agent_memory_ledger/backup_post.sh \
    && chmod +x /usr/share/agent_memory_ledger/restore_from_backup.sh \
    && chmod +x /usr/share/agent_memory_ledger/004_setup_agent_memory.sh \
    && chmod +x /usr/share/agent_memory_ledger/validate_agent_memory.sh \
    && chmod +x /usr/share/agent_memory_ledger/validate_governance.sh

WORKDIR /

# Build arguments
ARG BUILD_DATE
ARG BUILD_REF
ARG BUILD_VERSION
ARG BUILD_REPOSITORY

# Labels
LABEL \
    io.hass.name="Agent Memory Ledger (${BUILD_ARCH})" \
    io.hass.description="Home Assistant Add-on: Agent Memory Ledger" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.base.version="${BUILD_VERSION}" \
    io.hass.base.name="alpine" \
    io.hass.base.image="hassioaddons/base" \
    maintainer="GodSpeedAI" \
    org.opencontainers.image.title="Agent Memory Ledger (${BUILD_ARCH})" \
    org.opencontainers.image.description="Home Assistant Add-on: Agent Memory Ledger" \
    org.opencontainers.image.vendor="GodSpeedAI" \
    org.opencontainers.image.authors="GodSpeedAI" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.url="https://ghcr.io/godspeedai/agent-memory-ledger/${BUILD_ARCH}" \
    org.opencontainers.image.source="https://github.com/GodSpeedAI/hassos-addon-agent-memory-ledger" \
    org.opencontainers.image.documentation="https://github.com/GodSpeedAI/hassos-addon-agent-memory-ledger/blob/main/README.md" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.revision="${BUILD_REF}" \
    org.opencontainers.image.version="${BUILD_VERSION}"
