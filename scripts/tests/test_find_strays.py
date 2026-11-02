"""Chainless tests for the stray finder's selection, ordering, paging and recovery order."""

import find_strays as finder

FIRST = bytes.fromhex("11" * 32)
SECOND = bytes.fromhex("22" * 32)
THIRD = bytes.fromhex("33" * 32)
PARKING = bytes.fromhex("aa" * 32)


class StakingListStub:
    """A staking precompile that serves one coldkey's list by pages, counting the calls."""

    def __init__(self, hotkeys):
        self.hotkeys = hotkeys
        self.calls = 0
        self.functions = self

    def getStakingHotkeys(self, _coldkey, offset, limit):
        self.calls += 1
        page = self.hotkeys[offset:offset + limit]
        return type("Call", (), {"call": lambda _self, block_identifier=None: (page, len(self.hotkeys))})()


def hotkey(index: int) -> bytes:
    return index.to_bytes(32, "big")


def test_find_strays_skips_recorded_hotkeys_and_empty_entries():
    stakes = {FIRST: 5, SECOND: 7, THIRD: 0, PARKING: 9}
    strays = finder.find_strays([FIRST, SECOND, THIRD, PARKING], [FIRST, PARKING], stakes.__getitem__)
    assert strays == [finder.Stray(SECOND, 7)]


def test_find_strays_reports_parking_when_the_record_leaves_it_out():
    stakes = {FIRST: 5, PARKING: 2}
    strays = finder.find_strays([FIRST, PARKING], [FIRST], stakes.__getitem__)
    assert strays == [finder.Stray(PARKING, 2)]


def test_find_strays_orders_the_largest_pile_first():
    stakes = {FIRST: 1, SECOND: 3, THIRD: 2}
    strays = finder.find_strays([FIRST, SECOND, THIRD], [], stakes.__getitem__)
    assert [stray.hotkey for stray in strays] == [SECOND, THIRD, FIRST]


def test_find_strays_with_nothing_listed_is_empty():
    assert finder.find_strays([], [FIRST], lambda hotkey: 1) == []


def test_listed_hotkeys_walks_every_page():
    staking = StakingListStub([hotkey(i) for i in range(2 * finder.STAKING_LIST_PAGE + 2)])
    assert finder.listed_hotkeys(staking, b"", "latest") == staking.hotkeys
    assert staking.calls == 3


def test_listed_hotkeys_stops_after_a_list_that_fills_its_last_page():
    staking = StakingListStub([hotkey(i) for i in range(2 * finder.STAKING_LIST_PAGE)])
    assert finder.listed_hotkeys(staking, b"", "latest") == staking.hotkeys
    assert staking.calls == 2


def test_listed_hotkeys_of_an_empty_list_is_empty():
    staking = StakingListStub([])
    assert finder.listed_hotkeys(staking, b"", "latest") == []
    assert staking.calls == 1


def test_report_rows_names_each_pile_with_its_dry_run_verdict():
    strays = [finder.Stray(FIRST, 5), finder.Stray(SECOND, 1)]
    verdicts = {SECOND: "NothingToRecover"}
    rows = finder.report_rows(strays, lambda stray: verdicts.get(stray.hotkey))
    assert rows == [
        {"hotkey": "0x" + FIRST.hex(), "stake_rao": "5", "dry_run": "ok"},
        {"hotkey": "0x" + SECOND.hex(), "stake_rao": "1", "dry_run": "NothingToRecover"},
    ]


def test_recover_sends_a_pile_below_the_floor_once_a_parked_pile_can_carry_it():
    movable, below_floor = finder.Stray(FIRST, 500), finder.Stray(SECOND, 1)
    parked = []

    def verdict_of(stray):
        return None if stray is movable or parked else "NothingToRecover"

    def send(stray):
        parked.append(stray)
        return True

    assert finder.recover([movable, below_floor], verdict_of, send) == []
    assert parked == [movable, below_floor]


def test_recover_skips_a_pile_the_fresh_dry_run_refuses_and_reports_a_reverted_send():
    refused, reverting = finder.Stray(FIRST, 5), finder.Stray(SECOND, 3)
    sent = []

    def send(stray):
        sent.append(stray)
        return False

    assert finder.recover([refused, reverting], lambda stray: "NothingToRecover" if stray is refused else None, send) == [reverting]
    assert sent == [reverting]
