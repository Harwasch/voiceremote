"""Linux/BlueZ bench client. Run only at an operator's explicit direction."""
import argparse
import asyncio
import contextlib
import time

from bleak import BleakClient, BleakScanner
from dbus_fast import BusType, DBusError
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method

from wire import SERVICE, INFO, INPUT, PHONE, AUDIO, fragments, input_event, phone_state, version_info, BenchPolicy
from audio import WavRecorder


class NumericAgent(ServiceInterface):
    def __init__(self):
        super().__init__("org.bluez.Agent1")

    @method()
    async def RequestConfirmation(self, device: 'o', passkey: 'u'):
        print(f"Numeric Comparison: {passkey:06d}. Compare with the remote screen.")
        try:
            answer = await asyncio.wait_for(asyncio.to_thread(input, "Numbers match? Type yes: "), 25)
        except (TimeoutError, EOFError):
            raise DBusError("org.bluez.Error.Rejected", "confirmation timed out")
        if answer.strip().lower() != "yes":
            raise DBusError("org.bluez.Error.Rejected", "numbers not confirmed")

    @method()
    def RequestPinCode(self, device: 'o') -> 's':
        raise DBusError("org.bluez.Error.Rejected", "Numeric Comparison required")

    @method()
    def RequestPasskey(self, device: 'o') -> 'u':
        raise DBusError("org.bluez.Error.Rejected", "Numeric Comparison required")

    @method()
    def RequestAuthorization(self, device: 'o'):
        raise DBusError("org.bluez.Error.Rejected", "Just Works forbidden")

    @method()
    def AuthorizeService(self, device: 'o', uuid: 's'):
        raise DBusError("org.bluez.Error.Rejected", "unrelated profile forbidden")

    @method()
    def Cancel(self):
        print("Pairing canceled")

    @method()
    def Release(self):
        pass


@contextlib.asynccontextmanager
async def pairing_agent():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    path = "/org/voiceremote/agent"
    bus.export(path, NumericAgent())
    registered = False
    try:
        intro = await bus.introspect("org.bluez", "/org/bluez")
        manager = bus.get_proxy_object("org.bluez", "/org/bluez", intro).get_interface("org.bluez.AgentManager1")
        await manager.call_register_agent(path, "DisplayYesNo")
        registered = True
        await manager.call_request_default_agent(path)
        yield
    finally:
        if registered:
            await manager.call_unregister_agent(path)
        bus.unexport(path)
        bus.disconnect()


async def run(args):
    devices = await BleakScanner.discover(timeout=8, service_uuids=[SERVICE])
    for device in devices:
        print(device.address, device.name)
    if args.scan_only:
        return
    device = next((d for d in devices if not args.address or d.address.lower() == args.address.lower()), None)
    if device is None or (not args.address and len(devices) != 1):
        raise RuntimeError("choose one scanned remote using --address")
    policy = BenchPolicy(args.arm)
    changed = asyncio.Event()
    recorder = WavRecorder(args.save)  # checks libopus before connecting
    fatal = None
    audio_off = True

    def lost(reason):
        nonlocal audio_off
        recorder.close(True, reason)
        policy.lose()
        audio_off = True
        changed.set()
        print("Source interrupted:", reason, "; release/repress PTT or select OFF then REC")

    def on_input(_characteristic, data):
        nonlocal audio_off
        try:
            event = input_event(bytes(data))
            accepted, loss = policy.input(event)
            if not accepted:
                return
            print("Input", event)
            if loss:
                lost("Input gap or invalid transition")
            audio_off = not policy.streaming_allowed()
            recorder.expect_streaming(event["streaming"] and not audio_off)
            if audio_off and recorder.segment is not None:
                recorder.close(True, "local stop / loss before END")
            changed.set()  # Every Input is acknowledged, including start/stop snapshots.
        except ValueError as exc:
            lost(str(exc))

    def on_audio(_characteristic, data):
        nonlocal fatal
        try:
            # END is permitted after OFF; all data is rejected.
            if audio_off and (len(data) < 7 or not data[6] & 2):
                raise ValueError("Audio data while OFF / disarmed after loss")
            recorder.feed(data)
        except OSError as exc:
            fatal = exc
            changed.set()
        except Exception as exc:
            lost(str(exc))

    async with pairing_agent():
        print("Tap Pair on the remote for a new bond; confirm the number on both screens.")
        async with BleakClient(device, timeout=60) as client:
            await client.pair()
            info = version_info(bytes(await client.read_gatt_char(INFO)))
            print("Version/info", info)
            if not info["full_v1_capabilities"]:
                raise RuntimeError("Remote lacks required v1 capabilities; capture disabled")
            recorder.reassembly.maximum = info['maximum_packet']
            recorder.mtu = client.mtu_size
            print(f"Bleak public MTU={client.mtu_size}; BlueZ AcquireNotify/AcquireWrite can expose "
                  "the negotiated MTU, but Bleak's default StartNotify path reports 23. "
                  "Firmware serial logs the actual ATT MTU used for Audio.")
            await client.start_notify(INPUT, on_input)
            await client.start_notify(AUDIO, on_audio)
            budget = min(512, client.mtu_size - 3, args.budget)
            transaction = 0

            async def write_state(*, stop=False):
                nonlocal transaction
                latest = policy.latest
                arm = policy.arm() and not stop
                capture = (latest['capture'] if args.arm and latest else args.capture) if not stop else 0
                if capture == 0:
                    arm = False
                data = phone_state(latest['seq'] if latest else 0, target=args.target,
                                   link="BLE bench", error=args.error,
                                   capture=capture, recording=(1 if arm else (0 if capture == 0 else 2)) if args.arm else (0 if stop else args.recording),
                                   mode=latest['mode'] if latest else args.mode, arm=arm,
                                   snapshot=policy.snapshot_needed and not stop)
                transaction = (transaction + 1) & 0xffff
                for value in fragments(data, transaction, budget):
                    await client.write_gatt_char(PHONE, value, response=True)

            try:
                await write_state()  # Request a snapshot even when bonded CCCDs restored early.
                deadline = time.monotonic() + args.seconds
                while time.monotonic() < deadline:
                    if fatal is not None:
                        raise fatal
                    try:
                        await asyncio.wait_for(changed.wait(), min(.1, max(.001, deadline-time.monotonic())))
                    except TimeoutError:
                        pass
                    if changed.is_set():
                        changed.clear()
                        await write_state()
                    try:
                        recorder.watchdog()
                    except ValueError as exc:
                        lost(str(exc))
                await write_state(stop=True)
                # Allow firmware's empty END and stopped Input to arrive before disconnect.
                await asyncio.sleep(.3)
            finally:
                recorder.close(True, "client stopped / disconnected before END")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address")
    parser.add_argument("--save", metavar="PATH.wav", help="one 16 kHz mono WAV per segment")
    parser.add_argument("--scan-only", action="store_true")
    parser.add_argument("--target", default="PC", help="synthetic display label, never a device ID")
    parser.add_argument("--error", default="")
    parser.add_argument("--capture", type=int, choices=range(3), default=0)
    parser.add_argument("--recording", type=int, choices=range(4), default=0)
    parser.add_argument("--mode", type=int, choices=range(2), default=0)
    parser.add_argument("--arm", action="store_true")
    parser.add_argument("--budget", type=int, default=20, help="upper bound; default exercises MTU 23 path")
    parser.add_argument("--seconds", type=float, default=60)
    args = parser.parse_args()
    # Validate before accessing Bluetooth.
    phone_state(0, target=args.target, error=args.error, capture=args.capture,
                recording=args.recording, mode=args.mode, arm=args.arm)
    if not 7 <= args.budget <= 512:
        parser.error("budget must be 7..512")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
