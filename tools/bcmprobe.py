#!/usr/bin/env python3
"""bcmprobe: ask a Broadcom FullMAC (brcmfmac) Wi-Fi chip what it knows.

Talks to the firmware through brcmfmac's nl80211 vendor command
(OUI 00:10:18, subcmd 1 = "DCMD"), which forwards raw firmware ioctls.
Read-only by default; only --set-country changes anything (until reboot).

Usage (as root):
  sudo python3 bcmprobe.py [--iface wlan0] [--out DIR]
  sudo python3 bcmprobe.py --set-country US [--rev 0]
"""
import argparse, errno, os, socket, struct, sys

# ---- netlink / generic netlink constants ----
NETLINK_GENERIC = 16
NLM_F_REQUEST, NLM_F_ACK = 0x1, 0x4
NLMSG_ERROR, NLMSG_DONE = 0x2, 0x3
GENL_ID_CTRL, CTRL_CMD_GETFAMILY = 0x10, 3
CTRL_ATTR_FAMILY_ID, CTRL_ATTR_FAMILY_NAME = 1, 2
NL80211_CMD_VENDOR = 103
NL80211_ATTR_IFINDEX = 3
NL80211_ATTR_VENDOR_ID, NL80211_ATTR_VENDOR_SUBCMD, NL80211_ATTR_VENDOR_DATA = 195, 196, 197
BRCM_OUI, BRCMF_VNDR_CMDS_DCMD = 0x001018, 1
BRCMF_NLATTR_DATA = 2

# ---- firmware ioctls ----
WLC_GET_VAR, WLC_SET_VAR = 262, 263
WLC_GET_BANDLIST = 140
WLC_GET_SROM = 115

MAXCHUNK = 3800  # stay below one reply page


def nla(atype, payload):
    ln = 4 + len(payload)
    return struct.pack("<HH", ln, atype) + payload + b"\0" * ((4 - ln % 4) % 4)


def parse_attrs(buf):
    out, i = {}, 0
    while i + 4 <= len(buf):
        ln, atype = struct.unpack_from("<HH", buf, i)
        if ln < 4:
            break
        out[atype & 0x3FFF] = buf[i + 4:i + ln]
        i += (ln + 3) & ~3
    return out


class NL80211:
    def __init__(self):
        self.s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
        self.s.bind((0, 0))
        self.seq = 1
        self.fam = self._family("nl80211")

    def _send(self, mtype, cmd, attrs):
        self.seq += 1
        body = struct.pack("<BBH", cmd, 1, 0) + attrs
        hdr = struct.pack("<IHHII", 16 + len(body), mtype, NLM_F_REQUEST | NLM_F_ACK, self.seq, 0)
        self.s.send(hdr + body)
        replies = []
        while True:
            data = self.s.recv(65536)
            off = 0
            while off < len(data):
                ln, typ, _, _, _ = struct.unpack_from("<IHHII", data, off)
                msg = data[off + 16:off + ln]
                off += (ln + 3) & ~3
                if typ == NLMSG_ERROR:
                    err = struct.unpack_from("<i", msg)[0]
                    if err:
                        raise OSError(-err, os.strerror(-err))
                    return replies
                if typ == NLMSG_DONE:
                    return replies
                replies.append(msg[4:])  # strip genlmsghdr

    def _family(self, name):
        r = self._send(GENL_ID_CTRL, CTRL_CMD_GETFAMILY,
                       nla(CTRL_ATTR_FAMILY_NAME, name.encode() + b"\0"))
        return struct.unpack("<H", parse_attrs(r[0])[CTRL_ATTR_FAMILY_ID][:2])[0]

    def dcmd(self, ifindex, cmd, data=b"", retlen=0, set_=False):
        hdr = struct.pack("<IiIII", cmd, retlen, 20, 1 if set_ else 0, 0)
        attrs = (nla(NL80211_ATTR_IFINDEX, struct.pack("<I", ifindex)) +
                 nla(NL80211_ATTR_VENDOR_ID, struct.pack("<I", BRCM_OUI)) +
                 nla(NL80211_ATTR_VENDOR_SUBCMD, struct.pack("<I", BRCMF_VNDR_CMDS_DCMD)) +
                 nla(NL80211_ATTR_VENDOR_DATA, hdr + data))
        out = b""
        for r in self._send(self.fam, NL80211_CMD_VENDOR, attrs):
            vd = parse_attrs(r).get(NL80211_ATTR_VENDOR_DATA)
            if vd:
                out += parse_attrs(vd).get(BRCMF_NLATTR_DATA, b"")
        return out

    def getvar(self, ifx, name, params=b"", retlen=1024):
        return self.dcmd(ifx, WLC_GET_VAR, name.encode() + b"\0" + params, retlen)

    def setvar(self, ifx, name, value):
        return self.dcmd(ifx, WLC_SET_VAR, name.encode() + b"\0" + value, len(name) + 1 + len(value), True)


def cstr(b):
    return b.split(b"\0", 1)[0].decode(errors="replace")


def decode_chanspecs(raw):
    n = struct.unpack_from("<I", raw)[0]
    chans = {"2.4 GHz": set(), "5 GHz": set()}
    for k in range(min(n, (len(raw) - 4) // 4)):
        cs = struct.unpack_from("<I", raw, 4 + 4 * k)[0]
        band = "5 GHz" if (cs & 0xC000) == 0xC000 else "2.4 GHz"
        chans[band].add(cs & 0xFF)
    return {b: sorted(c) for b, c in chans.items()}


def step(title, fn):
    try:
        res = fn()
        print(f"[ok]   {title}: {res}")
        return True
    except OSError as e:
        print(f"[fail] {title}: {e.strerror} (errno {e.errno})")
    except Exception as e:  # decoding problems
        print(f"[fail] {title}: {e!r}")
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iface", default="wlan0")
    ap.add_argument("--out", default=os.path.expanduser("~/bcmprobe-out"))
    ap.add_argument("--set-country", metavar="CC", help="set firmware country (e.g. US, DE, TR) until reboot")
    ap.add_argument("--rev", type=int, default=0, help="country revision for --set-country (default 0)")
    a = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit("Run as root (sudo).")
    try:
        ifx = socket.if_nametoindex(a.iface)
    except OSError:
        sys.exit(f"No interface {a.iface}")
    try:
        nl = NL80211()
    except OSError as e:
        sys.exit(f"Cannot talk to nl80211 ({e.strerror}). Is the Wi-Fi driver loaded?")
    os.makedirs(a.out, exist_ok=True)

    def country():
        r = nl.getvar(ifx, "country", b"\0" * 12, 12)
        return f"abbrev={cstr(r[0:4])!r} rev={struct.unpack_from('<i', r, 4)[0]} ccode={cstr(r[8:12])!r}"

    if a.set_country:
        cc = a.set_country.upper()[:2].encode()
        val = cc.ljust(4, b"\0") + struct.pack("<i", a.rev) + cc.ljust(4, b"\0")
        step(f"set country {cc.decode()}/{a.rev}", lambda: (nl.setvar(ifx, "country", val), "accepted")[1])

    print(f"== {a.iface} (ifindex {ifx}) ==")
    step("firmware version", lambda: cstr(nl.getvar(ifx, "ver", retlen=256)))
    step("CLM version", lambda: cstr(nl.getvar(ifx, "clmver", retlen=512)).replace("\n", " | "))
    step("MAC (cur_etheraddr)", lambda: nl.getvar(ifx, "cur_etheraddr", retlen=6)[:6].hex(":"))
    step("country", country)

    def bandlist():
        r = nl.dcmd(ifx, WLC_GET_BANDLIST, b"\0" * 16, 16)
        n = struct.unpack_from("<I", r)[0]
        names = {1: "5 GHz", 2: "2.4 GHz"}
        return [names.get(struct.unpack_from("<I", r, 4 + 4 * i)[0], "?") for i in range(min(n, 3))]
    step("bands", bandlist)
    step("allowed channels (current country)",
         lambda: decode_chanspecs(nl.getvar(ifx, "chanspecs", b"\0" * 8, 2048)))

    # Board data stored on the chip. Each of these may simply be unsupported
    # by this firmware build; failures are expected for some.
    def srom():
        data = b""
        for off in range(0, 2048, 256):
            req = struct.pack("<II", off, 256) + b"\0" * 256
            r = nl.dcmd(ifx, WLC_GET_SROM, req, len(req))
            data += r[8:8 + 256]
        path = os.path.join(a.out, "srom.bin")
        open(path, "wb").write(data)
        nonblank = sum(1 for b in data if b not in (0x00, 0xFF))
        return f"{len(data)} bytes -> {path} ({nonblank} non-blank bytes)"
    step("SROM dump (WLC_GET_SROM)", srom)

    for var in ("otpdump", "cisdump", "nvram_dump"):
        def dump(v=var):
            r = nl.getvar(ifx, v, retlen=MAXCHUNK)
            path = os.path.join(a.out, f"{v}.txt")
            open(path, "wb").write(r.rstrip(b"\0"))
            return f"{len(r.rstrip(bytes(1)))} bytes -> {path}"
        step(f"{var}", dump)

    for var in ("boardtype", "boardrev", "sromrev", "ccode", "regrev", "aa2g", "aa5g", "txchain", "rxchain"):
        step(f"var {var}", lambda v=var: nl.getvar(ifx, v, retlen=16)[:4].hex())

    print(f"\nOutput files (if any) are in {a.out}")


if __name__ == "__main__":
    main()
