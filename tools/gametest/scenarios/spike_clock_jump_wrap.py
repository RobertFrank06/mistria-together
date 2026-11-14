"""Spike `clock_jump_wrap`: can CLOCK.jump be wrapped so outside skips are ignored? Runs the scenario that exercises it. Manual only."""
import importlib

NAME = "spike_clock_jump_wrap"
PLAYERS = 2
MANUAL = True
SETUP = "farm"

def run(session):
    importlib.import_module("gametest.scenarios.clock_no_skip").run(session)
