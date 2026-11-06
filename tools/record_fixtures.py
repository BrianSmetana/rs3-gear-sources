"""Fetches the wiki replies the tests asked for and stores them as fixtures.

test/run.lua answers each wiki request from test/fixtures (index.tsv maps a request path to a file). A request it has
no fixture for is appended to test/fixtures/missing.txt; run this script to fetch those, then run the tests again.
Lookups that chain (an item's recipe, then its materials' drops) may take a couple of rounds.
"""
import pathlib
import time
import urllib.request

FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "test" / "fixtures"
BASE = "https://runescape.wiki"
USER_AGENT = "RS3 Gear Sources plugin tests (fixture recorder)"


def main():
    missing = FIXTURES / "missing.txt"
    index = FIXTURES / "index.tsv"
    if not missing.exists():
        print("nothing missing")
        return
    known = {}
    if index.exists():
        for line in index.read_text(encoding="utf-8").splitlines():
            path, _, name = line.partition("\t")
            known[path] = name
    paths = [p for p in dict.fromkeys(missing.read_text(encoding="utf-8").splitlines()) if p and p not in known]
    with index.open("a", encoding="utf-8", newline="\n") as out:
        for path in paths:
            req = urllib.request.Request(BASE + path, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
            name = f"{len(known) + 1:03d}.json"
            (FIXTURES / name).write_bytes(body)
            out.write(f"{path}\t{name}\n")
            known[path] = name
            print(name, len(body), "bytes")
            time.sleep(0.5)  # be gentle with the wiki
    missing.unlink()


if __name__ == "__main__":
    main()
