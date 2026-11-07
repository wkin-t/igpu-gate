#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

BASE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(BASE))
SPEC = importlib.util.spec_from_file_location("igpu_session", BASE / "session.py")
SESSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SESSION)


def item(class_name, **values):
    return {"IOObjectClass": class_name, "IORegistryEntryChildren": [], **values}


def cold(with_probe=False):
    children = [item("IONDRVFramebuffer")]
    if with_probe:
        children.append(item("ReimsADLManualMatchProbe"))
    return item(
        "IOPCIDevice",
        IOServiceBusyState=0,
        **{"device-id": bytes.fromhex("ffff0000"), "IORegistryEntryChildren": children},
    )


def prepared():
    link = item(
        "ReimsADLDesktopLink",
        RCSADLPWorkaroundLive=True,
        RCSResetPSMIRegistered=True,
    )
    return item(
        "IOPCIDevice",
        IOServiceBusyState=0,
        **{
            "device-id": bytes.fromhex("ffff0000"),
            "IORegistryEntryChildren": [
                item("IONDRVFramebuffer"),
                item("IntelAccelerator", IOServiceState=0),
                link,
            ],
        },
    )


def published():
    link = item(
        "ReimsADLDesktopLink",
        RCSADLPWorkaroundLive=True,
        RCSResetPSMIRegistered=True,
    )
    return item(
        "IOPCIDevice",
        IOServiceBusyState=0,
        **{
            "device-id": bytes.fromhex("ffff0000"),
            "IORegistryEntryChildren": [
                item("IntelAccelerator", IOServiceState=2),
                item("ReimsIntelADLFramebuffer"),
                link,
            ],
        },
    )


class RuntimeStateTests(unittest.TestCase):
    def test_supported_states(self):
        self.assertEqual(SESSION.runtime_state(cold()), "cold")
        self.assertEqual(SESSION.runtime_state(prepared()), "prepared")
        self.assertEqual(SESSION.runtime_state(published()), "published")

    def test_duplicate_accelerator_is_refused(self):
        value = prepared()
        value["IORegistryEntryChildren"].append(
            item("IntelAccelerator", IOServiceState=0)
        )
        with self.assertRaisesRegex(RuntimeError, "exactly one IntelAccelerator"):
            SESSION.runtime_state(value)

    def test_published_without_reset_ready_link_is_refused(self):
        value = published()
        value["IORegistryEntryChildren"][-1]["RCSResetPSMIRegistered"] = False
        with self.assertRaisesRegex(RuntimeError, "ready DesktopLink"):
            SESSION.runtime_state(value)

    def test_loaded_identity_requires_one_matching_uuid(self):
        line = (
            "1 0 0x0 lab.reims.Component (1.0) "
            "12345678-1234-1234-1234-123456789ABC"
        )
        self.assertTrue(
            SESSION.loaded_entry(
                line,
                "lab.reims.Component",
                "12345678123412341234123456789ABC",
            )
        )
        with self.assertRaisesRegex(RuntimeError, "Unexpected loaded version"):
            SESSION.loaded_entry(
                line,
                "lab.reims.Component",
                "00000000000000000000000000000000",
            )

    def test_bundle_receipt_checks_every_file_and_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            executable = bundle / "Contents/MacOS/Component"
            info = bundle / "Contents/Info.plist"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"binary")
            info.write_bytes(b"plist")
            receipt = {
                "identifier": "lab.reims.Component",
                "hashes": {
                    "Contents/MacOS/Component": hashlib.sha256(b"binary").hexdigest(),
                    "Contents/Info.plist": hashlib.sha256(b"plist").hexdigest(),
                },
            }
            with patch.object(SESSION, "run", return_value=b"") as runner:
                SESSION.verify_receipt_bundle(bundle, receipt)
            runner.assert_called_once_with(
                ["codesign", "--verify", "--deep", "--strict", bundle], 30
            )

    def test_changed_receipt_file_is_refused_before_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            executable = bundle / "Contents/MacOS/Component"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"changed")
            receipt = {
                "identifier": "lab.reims.Component",
                "hashes": {"Contents/MacOS/Component": hashlib.sha256(b"expected").hexdigest()},
            }
            with patch.object(SESSION, "run") as runner, self.assertRaisesRegex(
                RuntimeError, "differs from this checkout build receipt"
            ):
                SESSION.verify_receipt_bundle(bundle, receipt)
            runner.assert_not_called()


class StartupFlowTests(unittest.TestCase):
    def execute(self, initial):
        state = {"pci": copy.deepcopy(initial)}
        actions = []
        video_calls = []

        def registry():
            return copy.deepcopy(state["pci"])

        def action(name, timeout=10):
            actions.append(name)
            if name == "SelfTest":
                state["pci"] = cold(with_probe=True)
            elif name in ("PrepareRuntime", "PrepareDisplay"):
                state["pci"] = prepared()
            elif name == "CommitDisplay":
                state["pci"] = published()
            else:
                raise AssertionError(name)

        def ensure_video(run, registry_function, objects, logdir):
            video_calls.append(SESSION.runtime_state(state["pci"]))
            return registry()

        with tempfile.TemporaryDirectory() as directory, patch.object(
            SESSION, "registry", side_effect=registry
        ), patch.object(SESSION, "action", side_effect=action), patch.object(
            SESSION, "ensure_video", side_effect=ensure_video
        ), patch.object(SESSION.time, "sleep"):
            final, processed = SESSION.activate(
                copy.deepcopy(initial), pathlib.Path(directory)
            )
        return final, processed, actions, video_calls

    def test_cold_start_runs_full_order_once(self):
        final, processed, actions, video_calls = self.execute(cold())
        self.assertEqual(SESSION.runtime_state(final), "published")
        self.assertEqual(
            actions,
            ["SelfTest", "PrepareRuntime", "PrepareDisplay", "CommitDisplay"],
        )
        self.assertEqual(processed, ["prepare", "commit", "video-verify"])
        self.assertEqual(video_calls, ["published"])

    def test_prepared_recovery_only_commits(self):
        final, processed, actions, video_calls = self.execute(prepared())
        self.assertEqual(SESSION.runtime_state(final), "published")
        self.assertEqual(actions, ["CommitDisplay"])
        self.assertEqual(processed, ["commit", "video-verify"])
        self.assertEqual(video_calls, ["published"])

    def test_published_recovery_only_checks_video(self):
        final, processed, actions, video_calls = self.execute(published())
        self.assertEqual(SESSION.runtime_state(final), "published")
        self.assertEqual(actions, [])
        self.assertEqual(processed, ["video-verify"])
        self.assertEqual(video_calls, ["published"])


def hidden_only():
    return item(
        "IOPCIDevice",
        IOServiceBusyState=0,
        **{
            "device-id": bytes.fromhex("ffff0000"),
            "IORegistryEntryChildren": [
                item("IONDRVFramebuffer"),
                item("ReimsADLManualMatchProbe"),
                item("IntelAccelerator", IOServiceState=0),
            ],
        },
    )


class AccelOnlyTests(unittest.TestCase):
    def execute(self, initial):
        state = {"pci": copy.deepcopy(initial)}
        actions = []

        def action(name, timeout=10):
            actions.append(name)
            if name == "SelfTest":
                state["pci"] = cold(with_probe=True)
            elif name == "PrepareRuntime":
                state["pci"] = hidden_only()
            else:
                raise AssertionError(f"accelerator-only mode must not call {name}")

        with tempfile.TemporaryDirectory() as directory, patch.object(
            SESSION, "registry", side_effect=lambda: copy.deepcopy(state["pci"])
        ), patch.object(SESSION, "action", side_effect=action), patch.object(SESSION.time, "sleep"):
            final, summary = SESSION.activate_accel_only(copy.deepcopy(initial), pathlib.Path(directory))
        return final, summary, actions

    def test_cold_start_stops_at_hidden_ready(self):
        final, summary, actions = self.execute(cold())
        self.assertEqual(actions, ["SelfTest", "PrepareRuntime"])
        self.assertEqual(summary["final_state"], "hidden")
        self.assertTrue(summary["firmware_framebuffer_retained"])

    def test_rerun_after_hidden_ready_does_nothing(self):
        _, summary, actions = self.execute(hidden_only())
        self.assertEqual(actions, [])
        self.assertEqual(summary["final_state"], "hidden")

    def test_published_accelerator_is_refused(self):
        value = hidden_only()
        value["IORegistryEntryChildren"][2]["IOServiceState"] = 2
        with self.assertRaisesRegex(RuntimeError, "never publishes"):
            SESSION.accel_only_state(value)

    def test_desktop_link_is_refused(self):
        value = hidden_only()
        value["IORegistryEntryChildren"].append(item("ReimsADLDesktopLink"))
        with self.assertRaisesRegex(RuntimeError, "DesktopLink must not exist"):
            SESSION.accel_only_state(value)

    def test_missing_firmware_framebuffer_is_refused(self):
        value = hidden_only()
        del value["IORegistryEntryChildren"][0]
        with self.assertRaisesRegex(RuntimeError, "firmware framebuffer"):
            SESSION.accel_only_state(value)

    def stop_outcome(self, after_prepare):
        def action(name, timeout=10):
            pass

        clock = iter(range(0, 1000, 10))
        with tempfile.TemporaryDirectory() as directory, patch.object(
            SESSION, "registry", side_effect=lambda: copy.deepcopy(after_prepare)
        ), patch.object(SESSION, "action", side_effect=action), patch.object(
            SESSION.time, "sleep"
        ), patch.object(SESSION.time, "monotonic", side_effect=lambda: next(clock)):
            with self.assertRaises(SESSION.AccelOnlyStopped) as caught:
                SESSION.activate_accel_only(cold(with_probe=True), pathlib.Path(directory))
        return caught.exception.outcome

    def test_no_instance_is_reported_as_probe_failure(self):
        self.assertEqual(self.stop_outcome(cold(with_probe=True)), "probe-failed")

    def test_instance_on_a_busy_bus_is_reported_as_start_stuck(self):
        value = hidden_only()
        value["IOServiceBusyState"] = 1
        self.assertEqual(self.stop_outcome(value), "start-stuck")

    def test_outcome_reaches_failure_record(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
            SESSION, "registry", side_effect=RuntimeError("no registry")
        ):
            logdir = pathlib.Path(directory)
            SESSION.save_failure(logdir, "accel-only", SESSION.AccelOnlyStopped("start-stuck", "stuck"))
            self.assertEqual(json.loads((logdir / "failure.json").read_text())["outcome"], "start-stuck")

    def test_success_summary_does_not_claim_gpu_function(self):
        _, summary, _ = self.execute(hidden_only())
        self.assertTrue(summary["start_returned_success"])
        self.assertFalse(summary["gpu_function_proven"])


class FullFlowDeviceTests(unittest.TestCase):
    def check(self, device_properties, initial=None):
        probe = item("ReimsADLManualMatchProbe", **device_properties)
        with_probe = cold()
        with_probe["IORegistryEntryChildren"].append(probe)
        actions = []

        def action(name, timeout=10):
            actions.append(name)

        start = initial if initial is not None else with_probe
        with patch.object(SESSION, "registry", side_effect=lambda: copy.deepcopy(with_probe)), patch.object(
            SESSION, "action", side_effect=action
        ), patch.object(SESSION.time, "sleep"):
            SESSION.require_full_flow_device(copy.deepcopy(start))
        return actions

    def test_adl_s_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "not ported"):
            self.check({"PhysicalDeviceID": 0x4680})

    def test_adl_p_is_allowed(self):
        self.assertEqual(self.check({"PhysicalDeviceID": 0x46a3}), [])

    def test_old_gate_without_identity_asks_for_reinstall(self):
        with self.assertRaisesRegex(RuntimeError, "reinstall"):
            self.check({})

    def test_self_test_runs_when_probe_is_absent(self):
        self.assertEqual(self.check({"PhysicalDeviceID": 0x46a3}, initial=cold()), ["SelfTest"])

    def test_prepared_and_published_states_never_call_self_test(self):
        # The gate refuses SelfTest twice per boot; these states already passed its device check.
        for state in (prepared(), published()):
            self.assertEqual(self.check({"PhysicalDeviceID": 0x4680}, initial=state), [])


if __name__ == "__main__":
    unittest.main()
