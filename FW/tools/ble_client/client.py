"""Linux/BlueZ bench client. Run only at an operator's explicit direction."""
import argparse
import asyncio
import contextlib

from bleak import BleakClient, BleakScanner
from dbus_fast import BusType, DBusError
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method

from wire import SERVICE, INFO, INPUT, PHONE, AUDIO, fragments, input_event, phone_state, version_info


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
    latest = None
    snapshot = asyncio.Event()
    unexpected_audio = asyncio.Event()

    def on_input(_characteristic, data):
        nonlocal latest
        event = input_event(bytes(data))
        latest = event["seq"]
        print("Input", event)
        if event["event"] == 0:
            snapshot.set()

    def on_audio(_characteristic, _data):
        unexpected_audio.set()

    async with pairing_agent():
        print("Tap Pair on the remote for a new bond; confirm the number on both screens.")
        async with BleakClient(device, timeout=60) as client:
            await client.pair()
            info = version_info(bytes(await client.read_gatt_char(INFO)))
            print("Version/info", info)
            if not info["full_v1_capabilities"]:
                print("Control-only stage: required Opus capability absent; full v1 capture unavailable.")
            await client.start_notify(INPUT, on_input)
            await client.start_notify(AUDIO, on_audio)
            # A bonded reconnect can send its snapshot before these subscriptions land.
            # Don't wait on it: the state write below requests a fresh one.
            try:
                await asyncio.wait_for(snapshot.wait(), 1)
            except TimeoutError:
                print("No snapshot yet; requesting one with the state write.")
            # BlueZ's public Bleak MTU may still report 23. Using its lower value is safe.
            # The OS response-write limit is 512 bytes; also clamp to the actual public MTU.
            budget = min(512, client.mtu_size - 3, args.budget)
            data = phone_state(latest or 0, target=args.target, link="BLE bench", error=args.error,
                               capture=args.capture, recording=args.recording, mode=args.mode,
                               arm=args.arm)
            for value in fragments(data, 0, budget):
                await client.write_gatt_char(PHONE, value, response=True)
            print(f"Phone state applied atomically ({len(data)} bytes; budget {budget}); listening")
            try:
                await asyncio.wait_for(unexpected_audio.wait(), args.seconds)
            except TimeoutError:
                pass
            else:
                raise RuntimeError("stage 1 must never notify Audio")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address")
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
