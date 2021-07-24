FROM bash

COPY bin/generateHrStatsForPeriod.sh /usr/local/bin

ENTRYPOINT [ "/usr/local/bin/bash", "-x", "/usr/local/bin/generateHrStatsForPeriod.sh" ]
