FROM amazonlinux:2

# Install the required components for the script to function.
RUN yum -y install \
    e2fsprogs \
    mdadm \
    nvme-cli \
    util-linux

# Install the script on the system.
COPY init_disks.sh /usr/local/bin/

ENTRYPOINT ["init_disks.sh"]
