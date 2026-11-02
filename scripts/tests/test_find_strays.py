"""Chainless tests for the stray finder's selection and ordering."""

import find_strays as finder

FIRST = bytes.fromhex("11" * 32)
SECOND = bytes.fromhex("22" * 32)
THIRD = bytes.fromhex("33" * 32)
PARKING = bytes.fromhex("aa" * 32)


def test_find_strays_skips_recorded_hotkeys_parking_and_empty_entries():
    stakes = {FIRST: 5, SECOND: 7, THIRD: 0, PARKING: 9}
    strays = finder.find_strays([FIRST, SECOND, THIRD, PARKING], [FIRST], PARKING, stakes.__getitem__)
    assert strays == [finder.Stray(SECOND, 7)]


def test_find_strays_orders_the_largest_pile_first():
    stakes = {FIRST: 1, SECOND: 3, THIRD: 2}
    strays = finder.find_strays([FIRST, SECOND, THIRD], [], PARKING, stakes.__getitem__)
    assert [stray.hotkey for stray in strays] == [SECOND, THIRD, FIRST]


def test_find_strays_reads_a_repeated_entry_once():
    reads = []

    def stake_of(hotkey):
        reads.append(hotkey)
        return 4

    strays = finder.find_strays([FIRST, FIRST], [], PARKING, stake_of)
    assert strays == [finder.Stray(FIRST, 4)]
    assert reads == [FIRST]


def test_find_strays_with_nothing_listed_is_empty():
    assert finder.find_strays([], [FIRST], PARKING, lambda hotkey: 1) == []


def test_report_rows_names_each_pile_with_its_dry_run_verdict():
    strays = [finder.Stray(FIRST, 5), finder.Stray(SECOND, 1)]
    verdicts = {SECOND: "NothingToRecover"}
    rows = finder.report_rows(strays, lambda stray: verdicts.get(stray.hotkey))
    assert rows == [
        {"hotkey": "0x" + FIRST.hex(), "stake_rao": "5", "dry_run": "ok"},
        {"hotkey": "0x" + SECOND.hex(), "stake_rao": "1", "dry_run": "NothingToRecover"},
    ]
