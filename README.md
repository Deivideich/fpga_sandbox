# FOGA_sandbox
Simple repositoy to store anything related to FPGAs

In order to use the Tang Nano 20k board in Ubuntu 22.04 without Gowin official IDE it is necessary to install software packages for the programming pipeline to actually work. For this, the ``setup_env.sh`` file will do the whole installation, just run

``` bash
chmod +x ./setup_env.sh
source ./setup_env.sh
```

After this, please check that the loading process works with the ``blink.v`` program inside  ``scripts`` folder by doing:

``` bash
make flash
```
