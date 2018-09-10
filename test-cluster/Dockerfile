####################################################################################################
#
# Copyright 2017 Nathanael Hübbe
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
####################################################################################################

#get the base system and install the necessary tools
from debian:9
run apt update && apt install -y munge
run apt update && apt install -y ssh

run apt update && apt install -y vim
run apt update && apt install -y gcc
run apt update && apt install -y make
run apt update && apt install -y pkg-config
run apt update && apt install -y python
run apt update && apt install -y man2html
run apt update && apt install -y mpich

run apt update && apt install -y libmariadbclient-dev
run apt update && apt install -y libnuma-dev
run apt update && apt install -y libpam0g-dev
run apt update && apt install -y libjson-c-dev
run apt update && apt install -y libibmad-dev
run apt update && apt install -y libibumad-dev
run apt update && apt install -y libhdf5-dev
run apt update && apt install -y liblz4-dev
run apt update && apt install -y libhwloc-dev
run apt update && apt install -y libipmimonitoring-dev
run apt update && apt install -y librrd-dev
run apt update && apt install -y libncurses5-dev
run apt update && apt install -y libglib2.0-dev
run apt update && apt install -y libgtk2.0-dev
run apt update && apt install -y liblua5.3-dev
run apt update && apt install -y libssl-dev
run apt update && apt install -y libmunge-dev
run apt update && apt install -y libcr-dev
run apt update && apt install -y libcurl4-openssl-dev

run apt update && apt install -y hdf5-helpers
run apt update && apt install -y netcat
run apt update && apt install -y bc
run apt update && apt install -y less

#setup for munge
run bash -c "mkdir -p /{etc,var/{lib,log,run}}/munge"
run bash -c "chown munge:munge /{etc,var/{lib,log,run}}/munge /usr/sbin/munged"
run chmod 700 /etc/munge /var/log/munge
run chmod 711 /var/lib/munge
run chmod 755 /var/run/munge
run chmod 700 /usr/sbin/munged
run chmod +s /usr/sbin/munged

#setup for ssh
run mkdir /var/run/sshd
run yes '' | adduser --disabled-password user
user user
run mkdir -p /home/user/.ssh
run chmod 700 /home/user/.ssh
user root
copy publicKey /home/user/.ssh/authorized_keys
run chown user:user /home/user/.ssh/authorized_keys
expose 22
run echo LANG=C.UTF-8 >> /home/user/.bashrc

#setup for slurm
run mkdir /repositories
volume /repositories/slurm
run mkdir /var/spool/slurmctl /var/spool/slurmd
run chown user:user /var/spool/slurmctl /var/spool/slurmd
copy slurm.conf /etc/slurm.conf
copy build-and-install-slurm /etc/build-and-install-slurm
run chmod 744 /etc/build-and-install-slurm
expose 6817 6818

#test epilog
copy srun_epilog /var/spool/slurmd/srun_epilog
run chmod 755 /var/spool/slurmd/srun_epilog
copy job_epilog /var/spool/slurmd/job_epilog
run chmod 755 /var/spool/slurmd/job_epilog

#build and install slurm
workdir "/repositories/slurm"
cmd /etc/build-and-install-slurm

#install our plugin
copy job-cost-meter.sh /var/spool/slurmd/job-cost-meter.sh
copy job-cost-meter.config /var/spool/slurmd/job-cost-meter.config
run chmod 755 /var/spool/slurmd/job-cost-meter.sh /var/spool/slurmd/job-cost-meter.config

#jobscript for testing
copy scontrol-test-job /home/user/scontrol-test-job
run chown user:user /home/user/scontrol-test-job
