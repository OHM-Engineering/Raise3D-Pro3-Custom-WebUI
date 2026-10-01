# Run host shell commands from Klipper g-code macros.
#
# Install this file as klippy/extras/gcode_shell_command.py, then declare:
#
#   [gcode_shell_command <name>]
#   command: /path/to/script.sh
#   timeout: 30.
#   verbose: True
#
# and call it from a macro with:
#
#   RUN_SHELL_COMMAND CMD=<name>
#
# This fork of Klipper runs under Python 2.7, so keep the syntax
# compatible with both Python 2 and 3.

import logging
import shlex
import subprocess
import threading


class ShellCommand:
    def __init__(self, config, gcode):
        self.gcode = gcode
        self.name = config.get_name().split()[-1]
        self.command = config.get('command')
        self.timeout = config.getfloat('timeout', 30., minval=0.)
        self.verbose = config.getboolean('verbose', False)

    def run(self, gcmd):
        logging.info("gcode_shell_command '%s': %s", self.name, self.command)
        if self.verbose:
            gcmd.respond_info("Running shell command '%s'" % (self.name,))
        try:
            proc = subprocess.Popen(shlex.split(self.command),
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
        except Exception as e:
            raise gcmd.error("Unable to start '%s': %s" % (self.name, e))
        timer = None
        if self.timeout:
            timer = threading.Timer(self.timeout, proc.kill)
            timer.start()
        output = proc.communicate()[0]
        if timer is not None:
            timer.cancel()
        if not isinstance(output, str):
            output = output.decode('utf-8', 'replace')
        output = output.strip()
        if self.verbose and output:
            gcmd.respond_info(output)
        if proc.returncode:
            raise gcmd.error("Shell command '%s' exited with code %s"
                             % (self.name, proc.returncode))
        if self.verbose:
            gcmd.respond_info("Shell command '%s' finished" % (self.name,))


def load_config_prefix(config):
    printer = config.get_printer()
    gcode = printer.lookup_object('gcode')
    commands = getattr(gcode, '_gcode_shell_commands', None)
    if commands is None:
        commands = {}
        gcode._gcode_shell_commands = commands

        def run_shell_command(gcmd):
            name = gcmd.get('CMD', None)
            if not name:
                raise gcmd.error("CMD parameter is required")
            command = commands.get(name)
            if command is None:
                raise gcmd.error("Unknown shell command '%s'" % (name,))
            command.run(gcmd)

        gcode.register_command('RUN_SHELL_COMMAND', run_shell_command,
                               desc="Run a configured gcode_shell_command")
    command = ShellCommand(config, gcode)
    commands[command.name] = command
    return command
