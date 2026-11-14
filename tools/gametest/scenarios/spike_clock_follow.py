"""Spike `clock_follow`: does a paused game catch up to session time when it closes? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_clock_follow"
PLAYERS = 2
MANUAL = True
SETUP = "farm"

def run(session):
    importlib.import_module("gametest.scenarios.clock_guest_menu").run(session)
