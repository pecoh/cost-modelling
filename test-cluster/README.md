This is the source for building a cluster environment to test the slurm plugin in.
This test cluster is built as docker containers.

Steps to create your own test cluster:

 0. Preconditions
 
      * Make sure you are in the right directory.
        If so, you should see the following:

            $ ls
            Dockerfile  execute  publicKey  slurm  slurm.conf

      * Make sure you have docker installed.
        If so, you should see something similar to:

            $ docker --version
            Docker version 17.06.0-ce, build 02c1d87

      * Make sure you have your git modules up to date:

            $ git submodule update

 1. Copy your public ssh key to the test cluster directory:

        $ cp ~/.ssh/id_rsa.pub publicKey

    This allows you to easily ssh into the running cluster later.

    This file cannot be provided by the repository, as it is totally dependent on your local machine for obvious reasons.
    As such, it is mentioned in .gitignore, so `git status` will not show you any "success" of this operation.
    However, the file must exist for the docker image to be built successfully.

 2. Start your test cluster with a simple

        $ ./execute

        ...

        started machine0 with IP address 172.28.1.0
        started machine1 with IP address 172.28.1.1
        started machine2 with IP address 172.28.1.2
        started machine3 with IP address 172.28.1.3
        started machine4 with IP address 172.28.1.4
        started machine5 with IP address 172.28.1.5
        started machine6 with IP address 172.28.1.6
        started machine7 with IP address 172.28.1.7
        started machine8 with IP address 172.28.1.8
        started machine9 with IP address 172.28.1.9

        press enter to kill cluster

    This will setup a container, copy the slurm source code into it, compile it, install it, configure it,
    and finally launch ten identical machines ready to be used as a cluster.
    The script will output the IP adresses of all the launched machines, and will then block for input, as shown above.

    **Warning**
    Compilation happens as root from within the container on the slurm directory that's mounted into the container.
    That means, that any compilation products are created by root, with all the consequences.

    Once you have no more use for your cluster, simply press enter, and the script will bring the entire cluster down automatically.

 ∞. Postconditions

      * ssh into your cluster by entering into a second terminal:

            $ ssh user@172.28.1.0
            The authenticity of host '172.28.1.0 (172.28.1.0)' can't be established.
            ECDSA key fingerprint is SHA256:<some-ssh-key-id>
            Are you sure you want to continue connecting (yes/no)? yes
            Warning: Permanently added '172.28.1.0' (ECDSA) to the list of known hosts.
            Enter passphrase for key '<your-home-director>/.ssh/id_rsa':

        Enter the passphrase to unlock the mentioned key, and you should get a shell on the first node of your cluster.

      * Check that your cluster works:

            user@machine0:~$ salloc -N 10
            salloc: Granted job allocation 2
            user@machine0:~$ srun hostname
            machine6
            machine3
            machine1
            machine8
            machine7
            machine9
            machine4
            machine0
            machine2
            machine5

        The order in which the machines appear is non-deterministic, of course, but you should see all ten machine names.
