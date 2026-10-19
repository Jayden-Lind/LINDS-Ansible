# Writes a summary of a playbook run to the JSON file that the environment
# variable LINDS_ANSIBLE_DEPLOY_SUMMARY names: the tasks that changed (or, in
# check mode, would change), the tasks that failed and the hosts that were
# unreachable. linds-ansible-deploy reads it. It does not change the normal
# output of the run.

DOCUMENTATION = """
name: deploy_summary
type: aggregate
short_description: Write the changed and failed tasks of a run to a JSON file
description:
  - Used by deploy/linds-ansible-deploy. Writes nothing if LINDS_ANSIBLE_DEPLOY_SUMMARY is not set.
requirements:
  - Enable it with ANSIBLE_CALLBACKS_ENABLED=deploy_summary.
"""

import json
import os

from ansible.plugins.callback import CallbackBase


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "deploy_summary"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self._path = os.environ.get("LINDS_ANSIBLE_DEPLOY_SUMMARY")
        self._changed = []
        self._failed = []
        self._unreachable = []

    @staticmethod
    def _entry(result):
        task = result._task
        return {
            "host": result._host.get_name(),
            "task": task.get_name(),
            "action": getattr(task, "resolved_action", None) or task.action,
        }

    def v2_runner_on_ok(self, result):
        if result._result.get("changed"):
            self._changed.append(self._entry(result))

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if not ignore_errors:
            entry = self._entry(result)
            entry["msg"] = str(result._result.get("msg", ""))[:300]
            self._failed.append(entry)

    def v2_runner_on_unreachable(self, result):
        self._unreachable.append(result._host.get_name())

    def v2_playbook_on_stats(self, stats):
        if not self._path:
            return
        with open(self._path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "changed": self._changed,
                    "failed": self._failed,
                    "unreachable": sorted(set(self._unreachable)),
                },
                f,
                indent=1,
            )
