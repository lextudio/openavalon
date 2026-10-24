#!/usr/bin/env python3
"""Download ProGPU's pinned ICU source archive (eng/native-edit-word-icu.json)
and verify its SHA-256. Prints the archive path. Retries dropped transfers."""
import hashlib, json, pathlib, sys, time, urllib.request

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: fetch-progpu-edit-word-icu.py <progpu-root> <output-directory>")
    pin = json.loads((pathlib.Path(sys.argv[1]) / "eng" / "native-edit-word-icu.json").read_text())
    out_dir = pathlib.Path(sys.argv[2]).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = out_dir / "icu-sources.tgz"
    if archive.is_file() and digest(archive) == pin["sourceSha256"]:
        print(archive)
        return
    partial = archive.with_name(archive.name + ".partial")
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(pin["sourceUrl"], timeout=120) as source, partial.open("wb") as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)
            break
        except OSError as error:
            if attempt == 5:
                raise
            print(f"ICU source download attempt {attempt} failed: {error}; retrying", file=sys.stderr)
            time.sleep(10 * attempt)
    if digest(partial) != pin["sourceSha256"]:
        partial.unlink()
        sys.exit("ProGPU EDIT ICU source differs from the reviewed pin.")
    partial.replace(archive)
    print(archive)

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

if __name__ == "__main__":
    main()
