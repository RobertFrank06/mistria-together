"""Spike: where is the shipping bin and does its content sync? Manual only."""
import time

NAME = "spike_bin"
PLAYERS = 2
SETUP = "farm"
MANUAL = True


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    print("host before", host.cmd({"cmd": "bin_info"}))
    print("guest before", guest.cmd({"cmd": "bin_info"}))
    host.cmd({"cmd": "bin_put", "count": 5})
    for i in range(4):
        time.sleep(2)
        print(i, "host", host.cmd({"cmd": "bin_value"}), host.cmd({"cmd": "bin_info"}))
        print(i, "guest", guest.cmd({"cmd": "bin_value"}), guest.cmd({"cmd": "bin_info"}))
