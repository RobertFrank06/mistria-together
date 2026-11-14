"""Spike `summary_hold`: can the overnight summary's button be locked from the tick and released? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_summary_hold"
PLAYERS = 2
MANUAL = True


def run(session):
    importlib.import_module("gametest.scenarios.night_faint_holds").run(session)
