# Contributing
Feel free to add any missing features or CAN HATs in a pull request.

## Adding support for new CAN HATs
CANlosetup is modular and makes it pretty easy to add support for any CAN HATs you have

### Naming conventions
Before adding support for a CAN HAT decide on a consistent name for all of the files. (ex. `CANHAT`)

### CAN HAT `config.txt` entry
Create a file in the [`config/`](config) directory called `CANHAT.txt` and upload the part of your `config.txt` file which made it work

### CAN HAT systemd service
Create a file in the [`service/`](service) directory called `CANHAT.sh` and write a bash script which brings up the CAN HAT. Some generic functions are available to use in the [`common/canlosetup.sh`](common/canlosetup.sh) file

## Adding missing features
If you have an idea which would make CANlosetup more useful, please feel free to add it! (It doesn't have to be CAN HAT related)
