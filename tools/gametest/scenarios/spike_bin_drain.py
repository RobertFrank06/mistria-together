"""Spike `bin_drain`: can the shipping bin payout be cancelled during the summary? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_bin_drain"
PLAYERS = 2
MANUAL = True
SETUP = "farm"

def run(session):
    importlib.import_module("gametest.scenarios.money_bin_split").run(session)
