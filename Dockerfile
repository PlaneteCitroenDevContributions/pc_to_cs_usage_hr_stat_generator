FROM fedora

RUN dnf install -y gnumeric emacs-nox \
    && dnf clean all

COPY bin/generateHrStatsForPeriod.sh /usr/local/bin

ENTRYPOINT [ "/bin/bash", "-x", "/usr/local/bin/generateHrStatsForPeriod.sh" ]
#ENTRYPOINT [ "/usr/local/bin/bash", "/usr/local/bin/generateHrStatsForPeriod.sh" ]
