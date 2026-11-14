"""Spike `load_with_ident`: does LoadState with an overwritten game_ident save and load as that farm? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_load_with_ident"
PLAYERS = 2
MANUAL = True
MODES = ["new", "title"]

def run(session):
    importlib.import_module("gametest.scenarios.farmhand_rejoin").run(session)
