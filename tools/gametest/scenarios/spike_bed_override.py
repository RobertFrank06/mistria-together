"""Spike `bed_override`: does an object.interact override claim beds and leave the game's sleep scene to run later? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_bed_override"
PLAYERS = 2
MANUAL = True


def run(session):
    importlib.import_module("gametest.scenarios.night_both_sleep").run(session)
