"""Package source-only teammate handoffs; never include local data or credentials."""
import argparse
import shutil
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
IGNORE = {".git", ".venv", "__pycache__", ".pytest_cache", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store", ".env"}


def source_file(path):
    generated_ios = path.parts[:3] == ("clients", "ios", "Configuration")
    retired_preview = str(path) in {"docs/prototype-preview.jpg", "docs/ios-preview.jpg", "docs/ios-capture.jpg", "docs/ios-discovery.jpg"}
    environment_file = path.name.startswith(".env") and path.name != ".env.example"
    return not generated_ios and not retired_preview and not environment_file and not any(part in IGNORE or part.endswith(".xcodeproj") or part.endswith(".xcworkspace") for part in path.parts) and path.suffix not in {".db", ".pyc"} and not path.name.endswith((".db-wal", ".db-shm"))


def archive(path, files, prefix=""):
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as bundle:
        for source, relative in sorted(files):
            bundle.write(source, prefix + str(relative))
    print(path.relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="Include the backend and both client frameworks")
    parser.add_argument("--sidepanel", action="store_true", help="Package the Mynah Finds 0.4 side-panel extension only")
    args = parser.parse_args()
    DIST.mkdir(exist_ok=True)
    if args.sidepanel:
        source = ROOT / "experiments/chrome-sidepanel"
        # Explicit source types exclude credentials, test data and local browser state.
        files = [p for p in source.iterdir() if p.suffix in {".js", ".html", ".css"} or p.name in {"manifest.json", "README.md", "TESTING.md"}]
        files += list((source / "lib").glob("*.js")) + list((source / "icons").glob("*.png"))
        archive(DIST / "mynah-finds-sidepanel.zip", [(p, p.relative_to(source)) for p in files if p.is_file()])
        return
    for directory in ["extension/lib", "frontend/lib"]:
        bundled = ROOT / directory / "client.js"
        bundled.parent.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "clients/javascript/client.js", bundled)
    unpacked = DIST / "chrome-extension"
    if unpacked.exists():
        shutil.rmtree(unpacked)
    shutil.copytree(ROOT / "extension", unpacked, ignore=shutil.ignore_patterns("tests", "package.json", ".DS_Store"))
    archive(DIST / "mymah-finds-chrome-extension.zip", [(p, p.relative_to(unpacked)) for p in unpacked.rglob("*") if p.is_file()])
    if args.all:
        entries = ["backend", "clients", "contracts", "docs", "extension", "frontend", "scripts", "README.md", "Makefile", "pyproject.toml", "requirements.lock", "alembic.ini", "compose.yaml", ".env.example", ".gitignore", "reports/Immediately usable product datasets.md"]
        files = []
        for entry in entries:
            base = ROOT / entry
            for path in ([base] if base.is_file() else base.rglob("*")):
                if path.is_file() and source_file(path.relative_to(ROOT)):
                    files.append((path, path.relative_to(ROOT)))
        archive(DIST / "mymah-finds-framework.zip", files, "mymah-finds/")


if __name__ == "__main__":
    main()
