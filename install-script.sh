#!/bin/bash
set -ex
IP=`hostname -i`

# prepare cassandra data dir
mkdir -p /var/lib/cassandra

# Add cassandra user and group (more details on group missing?)
groupadd Cassandra
useradd -M -b /var/lib -s /bin/false -G Cassandra cassandra

# partition /dev/xvdb
parted --script /dev/xvdb mklabel gpt
sleep 5
parted --script --align optimal /dev/xvdb mkpart primary ext4 2MiB 100%
sleep 5
mkfs.ext4 /dev/xvdb1
sleep 5
# mount /dev/xvdb1 on /var/lib/cassandra
mount -t ext4 /dev/xvdb1 /var/lib/cassandra
chown -R cassandra: /var/lib/cassandra

sed -i 's|/dev/xvdb.*|/dev/xvdb /mnt auto defaults,nofail,x-systemd.requires=cloud-init.service,comment=cloudconfig 0 2|' /etc/fstab

# install cassandra
echo "deb http://www.apache.org/dist/cassandra/debian 37x main" | tee -a /etc/apt/sources.list.d/cassandra.sources.list
curl https://www.apache.org/dist/cassandra/KEYS | apt-key add -
apt-get update --assume-yes --quiet
apt-get install --assume-yes --quiet cassandra cassandra-tools python-pip lzop libssl-dev sysstat jq
# stop, and prepare for reconfiguration
sleep 60
systemctl stop cassandra.service
sleep 10


# fix cqlsh
export CQLSH_NO_BUNDLED=true && echo "export CQLSH_NO_BUNDLED=true" >> /home/ubuntu/.bashrc
export LC_ALL=en_US.UTF-8 && echo "export LC_ALL=en_US.UTF-8" >> /home/ubuntu/.bashrc
pip install cassandra-driver awscli

# configure kernel parameters
cat <<EOF > /etc/sysctl.d/50-cassandra.conf
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 40960
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
vm.max_map_count = 1048575
EOF
sysctl -p /etc/sysctl.d/50-cassandra.conf

# optimize IO subsystem
echo deadline > /sys/block/xvdb/queue/scheduler
touch /var/lock/subsys/local
echo 0 > /sys/class/block/xvdb/queue/rotational
echo 8 > /sys/class/block/xvdb/queue/read_ahead_kb

# set user resource limits
cat <<EOF > /etc/security/limits.d/cassandra.conf
cassandra - memlock unlimited
cassandra - nofile 100000
cassandra - nproc 32768
cassandra - as unlimited
EOF

# disable swap
swapoff --all

# disable transparent hugepages
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# lookup ip addresses of Cassandra seed nodes
lookup_seed_node_ip() {
  # Resolve IP address from DNS name
  echo "lookup IP for hostname: " $1
  lookup=`host $1 | xargs | awk '{print $NF," "}'`
  if [ $lookup == `echo $lookup | sed 's/\./something/g'` ]
  then
    echo 'wait a minute...'
    echo 'strange IP: ' $lookup
    sleep 10
    lookup_seed_node_ip $1
    return $?
  else
    echo 'IP turns out to be: ' $lookup
    return 0
  fi
}

declare -a hostnames=("cassandra-seed-0.infrastructure.linkfire" "cassandra-seed-1.infrastructure.linkfire" "cassandra-seed-2.infrastructure.linkfire")
for i in "${hostnames[@]}"
do
  lookup_seed_node_ip "$i"
  ip_list=$ip_list","$lookup
done
# strip the first "," (comma)
seed_ips=${ip_list#?}
# strip all spaces
seed_ips=$(echo $seed_ips | sed 's/\ //g')
# surround with quotation marks (")
seed_ips='"'$seed_ips'"'

# configure cassandra cluster
sed -i -e 's/Test Cluster/Linkfire Cluster/' /etc/cassandra/cassandra.yaml
sed -i -e "s/localhost/$IP/" /etc/cassandra/cassandra.yaml
sed -i -e 's/endpoint_snitch: SimpleSnitch/endpoint_snitch: Ec2Snitch/' /etc/cassandra/cassandra.yaml
sed -i -e "s/- seeds: .*/- seeds: ${seed_ips}/" /etc/cassandra/cassandra.yaml
sed -i -e "s/incremental_backups:.*/incremental_backups: true/" /etc/cassandra/cassandra.yaml

# start cassandra back up
rm -rf /var/lib/cassandra/data/system/*
sleep 2
systemctl start cassandra.service
systemctl enable cassandra.service

# install nodetool tab completion
curl https://raw.githubusercontent.com/cscetbon/cassandra/nodetool-completion/etc/bash_completion.d/nodetool > /etc/bash_completion.d/nodetool

# set some sane cqlshrc defaults
mkdir /home/ubuntu/.cassandra
touch /home/ubuntu/.cassandra/cqlshrc
cat <<EOF > /home/ubuntu/.cassandra/cqlshrc
[connection]
request_timeout=3600
timeout=30
client_timeout=3600
hostname=$HOSTNAME
EOF
chown -R ubuntu: /home/ubuntu

# schedule daily nodetool-repair job, at (sort of) random hour
somenum=$(hostname -i | cut -d "." -f 4);
hour="$(($somenum%24))"
echo "#0 ${hour} * * *  nodetool repair -pr" | crontab -u cassandra -
