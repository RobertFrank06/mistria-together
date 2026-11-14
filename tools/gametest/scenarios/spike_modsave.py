"""Spike `modsave`: does the mod's save sidecar round-trip for a farmhand save? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_modsave"
PLAYERS = 2
MANUAL = True
MODES = ["new", "title"]

def run(session):
    importlib.import_module("gametest.scenarios.farmhand_first_join").run(session)
