FROM fedora

ENV STAT_DATA_DIR=/var/pc_stats
ENV TZ=Europe/Paris

RUN dnf install -y gnumeric emacs-nox netcat \
    && dnf clean all

COPY bin/generateHrStatsForPeriod.sh /usr/local/bin
COPY bin/generateAndSendGELFMessages.sh /usr/local/bin

# defaults to NextCloud user/group
USER 33:33

#ENTRYPOINT [ "/bin/bash", "-x", "/usr/local/bin/generateHrStatsForPeriod.sh" ]
#ENTRYPOINT [ "/usr/local/bin/bash", "/usr/local/bin/generateHrStatsForPeriod.sh" ]
