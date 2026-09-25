# Copyright (c) 2017 Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

from decimal import Decimal, InvalidOperation

from ansible.errors import AnsibleFilterError

# Module-level on purpose: a double-underscore name read inside the class is
# mangled to _FilterModule__ERROR_MSG, which does not exist.
ERROR_MSG = "Not a valid cpu value. Cannot process value"

class FilterModule(object):
    def filters(self):
        return {
            'cpu_string_to_decimal': self.cpu_string_to_decimal
        }
    def cpu_string_to_decimal(self, cpu_string):

        # verify if cpu_string is a string
        if not isinstance(cpu_string, str):
            raise AnsibleFilterError(ERROR_MSG)

        # A Kubernetes CPU quantity is either millicores ("1500m") or cores,
        # which may be fractional ("1.5"). Both round down to whole CPUs.
        try:
            if cpu_string.endswith('m'):
                cpu = Decimal(cpu_string[:-1]) / 1000
            else:
                cpu = Decimal(cpu_string)
        except InvalidOperation:
            raise AnsibleFilterError("%s: %r" % (ERROR_MSG, cpu_string))

        if not cpu.is_finite():
            raise AnsibleFilterError("%s: %r" % (ERROR_MSG, cpu_string))

        return int(cpu)
