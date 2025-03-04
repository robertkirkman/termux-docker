##############################################################################
# Bootstrap Termux environment.
FROM scratch AS bootstrap

ARG ROOTFS
ARG TERMUX_APP_PACKAGE
ARG TERMUX_PREFIX

# Install generated rootfs containing:
# - termux bootstrap
# - aosp-libs (bionic libc, linker, boringssl, zlib, libicuuc, debuggerd)
# - aosp-utils (toybox, mksh, iputils)
# - libandroid-stub
# - dnsmasq
# Since /system is now a symbolic link to $PREFIX/opt/aosp,
# which has contents that can be updated by the system user via apt,
# the entire rootfs is now be owned by the system user (1000:1000).
COPY --chown=1000:1000 ${ROOTFS} /

# Docker uses /bin/sh by default, but we don't have it.
ENV PATH=/system/bin
SHELL ["sh", "-c"]

# Install updates and cleanup
# Start dnsmasq to resolve hostnames, and,
# for some reason the -c argument of toybox-su is not working,
# so this odd-looking script forces the update process
# to work using the -s argument of toybox-su instead, which is working.
RUN sh -T /dev/ptmx -c "$TERMUX_PREFIX/bin/dnsmasq -u root -g root --pid-file=/dnsmasq.pid" && \
   sleep 1 && \
   echo '#!/system/bin/sh' > /update.sh && \
   echo "PATH=$TERMUX_PREFIX/bin" >> /update.sh && \
   echo 'pkg update' >> /update.sh && \
   echo 'apt-get upgrade -o Dpkg::Options::=--force-confnew -y' >> /update.sh && \
   chmod +x /update.sh && \
   su system -s /update.sh && \
   rm -f /update.sh && \
   rm -rf ${TERMUX_PREFIX}/var/lib/apt/* && \
   rm -rf ${TERMUX_PREFIX}/var/log/apt/* && \
   rm -rf /data/data/${TERMUX_APP_PACKAGE}/cache/apt/*

##############################################################################
# Create final image.
FROM scratch

ARG TERMUX_BASE_DIR
ARG TERMUX_PREFIX

ENV ANDROID_DATA=/data
ENV ANDROID_ROOT=/system
ENV HOME=${TERMUX_BASE_DIR}/home
ENV LANG=en_US.UTF-8
ENV PATH=${TERMUX_PREFIX}/bin
ENV PREFIX=${TERMUX_PREFIX}
ENV TMPDIR=${TERMUX_PREFIX}/tmp
ENV TZ=UTC
ENV TERM=xterm

COPY --from=bootstrap / /

WORKDIR ${TERMUX_BASE_DIR}/home
SHELL ["sh", "-c"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["login"]
