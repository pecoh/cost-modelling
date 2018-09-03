Setting up the SLURM repository
===============================

Background:
The job cost meter relies on our own extension to the `scontrol` command,
and the slurm source code is included in this repo as a submodule.
As such, you need to perform the following steps to get compilation working:

 0. First time only:
    In the pecoh base directory, do

        $ git submodule init
        $ git submodule update

    The first one tells git that we have submodules it needs to manage,
    the second causes it to actually clone into the upstream slurm repo.

    The second command will actually say that it failed because the referenced commit could not be found.
    This is expected, and the command is not effect-less:
    It correctly clones the repo from upstream.

 1. Add our own extension to the slurm repo.
    The commits containing the proposed slurm extension are checked into git
    as a git bundle at 'job-cost-meter/scontrolAdditions.gitbundle'.
    Run the following to add them to the slurm submodule repo:

        $ cd test-cluster/slurm/
        $ git bundle unbundle ../../scontrolAdditions.gitbundle
        $ cd ../..

 2. Ensure that the slurm submodule is up-to-date:

        $ git submodule update

    This time, it should work without error.

After this, you can proceed with the instructions in 'test-cluster/README.md'.
Step 2. will need to be repeated whenever you checkout a commit that references a different SLURM commit,
step 1. will need to be repeated whenever step 2. fails due to an unresolvable reference.
