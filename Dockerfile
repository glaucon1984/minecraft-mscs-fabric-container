# MinecraftServerControl
#
# This Dockerfile creates a Docker image for running running and controlling
# Minecraft servers. It is based off of gliderlabs alpine image and the
# MinecraftServerControl script.
FROM alpine

# Change this to true or pass --build-arg EULA=true into the docker build call
# to accept Mojang's EULA.
ARG EULA=true

# The default world name. You can mount a volume into ${LOCATIONN}/worlds
# to load already existing worlds into new instances of this image.
ARG WORLD_NAME=default

# Select the Fabric-enabled Minecraft Server version
# Check available versions at https://fabricmc.net/use/server/
ARG MINECRAFT_VER=1.19.2
ARG FABRIC_LOADER_VER=0.14.11
ARG INSTALLER_VER=0.11.1

# Indicate how much RAM will be available for the server in Megabytes
ARG RAM_AMMOUNT=4096

# Choose backup frequency
# [<15min>,<hourly>,<daily>,<weekly>,<monthly>]
ARG BACKUP_PERIOD=daily
# And retention (in days)
ARG BACKUP_RETENTION=7

# **** ENV ****
# Configuration of the Alpine image environment
RUN apk add --update \
    # add alpine  community reporisory to install tini
    --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ \
    # install tini to have a proper init process
    tini && \
    rm -rf /var/cache/apk/*
RUN apk --update add\
    # install tools & requirements for mscs
    sudo procps coreutils \
    git bash bash-completion rdiff-backup busybox-openrc \
    python3 openjdk17-jre perl perl-lwp-protocol-https \
    perl-json perl-libwww socat wget ncurses rsync && \
    rm -rf /var/cache/apk/*
# make sure to run everything in bash
RUN ln -sf /bin/bash /bin/sh

# **** MSCS ****
# We are running mscs setup root in the container
ARG USER_NAME=root
ARG LOCATION=/opt/mscs
# install mscs
RUN mkdir -p ${LOCATION}
RUN git clone https://github.com/MinecraftServerControl/mscs.git ${LOCATION}
# we are not using `make install`, because we do not intend to create an
# additional user et all
RUN adduser --disabled-password minecraft
RUN ln -s ${LOCATION}/mscs /usr/local/bin
RUN chmod +x ${LOCATION}/msctl
RUN ln -s ${LOCATION}/msctl /usr/local/bin
# create mscs default configuration
RUN mkdir -p /etc/default
RUN echo USER_NAME=${USER_NAME} >>/etc/default/mscs
RUN echo LOCATION=${LOCATION} >>/etc/default/mscs
WORKDIR ${LOCATION}

# **** Fabric ****
# Download indicated server version of Fabric
RUN mkdir -p ${LOCATION}/server
ENV DOWNLOAD_URL=https://meta.fabricmc.net/v2/versions/loader/$MINECRAFT_VER/$FABRIC_LOADER_VER/$INSTALLER_VER/server/jar
ENV DOWNLOAD_LOCATION=$LOCATION/server/fabric-server-mc.$MINECRAFT_VER-loader.$FABRIC_LOADER_VER-launcher.$INSTALLER_VER.jar
RUN wget -O ${DOWNLOAD_LOCATION} ${DOWNLOAD_URL}
# Setup the default world in case no existing worlds are mounted
RUN chown -R minecraft ${LOCATION}
RUN mscs create ${WORLD_NAME} 25565
# Configure world to use custom JAR from Fabric
RUN mkdir -p /opt/mscs/worlds/${WORLD_NAME}
ENV SERVER_JAR=mscs-server-jar=fabric-server-mc.${MINECRAFT_VER}-loader.${FABRIC_LOADER_VER}-launcher.${INSTALLER_VER}.jar
ENV WORLD_CONFIG=/opt/mscs/worlds/${WORLD_NAME}/mscs.properties
RUN echo ${SERVER_JAR} >> ${WORLD_CONFIG}
#RUN echo 'mscs-server-url=' >> /opt/mscs/worlds/fabric-example/mscs.properties

# **** EULA ****
# EULA has to be "true" for the Minecraft server to start
RUN echo "eula=${EULA}" >${LOCATION}/worlds/${WORLD_NAME}/eula.txt

# **** BACKUPS ****
# MSCS will run a backup on all worlds, by default, daily
RUN mkdir -p ${LOCATION}/backups
RUN chown -R minecraft ${LOCATION}/backups
RUN echo "mscs backup" > /etc/periodic/${BACKUP_PERIOD}/mscs_backup.sh
# Length in days that logs survive. A value less than 1 disables log deletion.
RUN echo "mscs-log-duration=${BACKUP_RETENTION}" >> /opt/mscs/mscs.defaults

# **** RAM ****
# Configure how much RAM will be available for the server
RUN echo "mscs-default-maximum-memory=${RAM_AMMOUNT}M" >> /opt/mscs/mscs.defaults

# First run
RUN echo "minecraft ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/minecraft
USER minecraft
RUN mscs start

# dump minecraft version. can be useful for tagging of the image
    #alias exit, so sourcing msctl does not exit the shell
RUN alias exit=true && \
    # source msctl to get access to it's functions. redirect output, we don't
    # need it.
    . ${LOCATION}/msctl >/dev/null && \
    # echo Minecraft version using msctl's getCurrentMinecraftVersion function
    echo Minecraft Version: $(getCurrentMinecraftVersion ${WORLD_NAME})

# Mount existing worlds that you want to run into this volume.
VOLUME ${LOCATION}/worlds
# Mount a location for your backups into this volume. Fair warning: rdiff-backup
# is unable to write to curlftpfs destinations. I tried. For long.
VOLUME ${LOCATION}/backups
# Mount scripts to run in cron into /etc/periodic/[folder], where [folder] is
# one (or multiple) of 15min, hourly, daily, weekly or monthly. E.g. for
# syncing mirrored worlds or creating backups.
# VOLUME /etc/periodic

EXPOSE 25565

# use tini as our entrypoint so we have a proper init script
ENTRYPOINT ["tini", "--"]
    # start cron
CMD crond ; \
    # Avoid permissions issues if we imported a world/backup
    sudo chown -R minecraft /opt/mscs ; \
    # start the minecraft servers
    mscs start && \
    # watch the first running minecraft server
    # this will allow you to follow what happens, but will also prevent the
    # container from exiting. If you intent on starting and stopping servers in
    # the container without it exiting, then replace the following line with a
    # simple tail -f /dev/null
    # mscs watch `mscs ls running | head -n 1 | cut -f1 -d: | tr -d '[:blank:]'`
    tail -f /dev/null